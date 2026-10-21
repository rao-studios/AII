//
//  Database.Registry.swift
//  Thread
//
//  Created by Ritesh Pakala on 11/08/25.
//  Copyright © 2026 Rao Studios LLC.
//

import AII
import Foundation

typealias DocumentID = String
typealias GroupID = String
typealias OwnerID = String

/// Registry for owners and their documents.
struct ThreadRegistry: Codable {
    // All documents under a owner.
    var ownersDocuments: [Owner : [DocumentID]] = [:]
    // All owners of a document (one-to-many CID ownership).
    var documentOwners: [DocumentID : Set<Owner>] = [:]
    // All groups a document belongs to — one per linked owner.
    // This is the union index used by search diversity injection.
    // Per-owner group assignment lives in `ownerDocumentGroup`.
    var documentGroups: [DocumentID : Set<GroupID>] = [:]
    // Per-owner group assignment: [OwnerID: [DocumentID: GroupID]].
    // Authoritative for owner-scoped operations (removal, updateGroup, GroupKind resolution).
    // Kept in sync with `documentGroups`.
    var ownerDocumentGroup: [OwnerID : [DocumentID : GroupID]] = [:]
    // All groups under a owner.
    // Database.Group in this scope will not have document values.
    var ownersGroups: [Owner : [Database.Group]] = [:]
    // Associated owner with a GroupID.
    var groupOwners: [GroupID : Owner] = [:]
    // Documents are stored in groups.
    var groups: [GroupID : [DocumentID]] = [:]
    // Files that are publicly available for aggregation
    // or earning royalties back to their relative owners.
    var documentAccess: [DocumentID : Access] = [:]
    // Groups that are publicly available for aggregation
    var groupAccess: [GroupID : Access] = [:]
    // Pre-computed set of document IDs whose access is `.available`.
    // Updated by `updateDocumentAccess(for:state:)` and `remove(documentId:)`.
    // Eliminates the O(D) scan of `documentAccess` on every global-scope query.
    var availableDocumentIds: Set<DocumentID> = []
    // Pre-computed set of group IDs whose access is `.available`.
    // Updated by `updateGroupAccess(for:state:)`.
    // Eliminates the O(G) scan of `groupAccess` on every libraryRequest.
    var availableGroupIds: Set<GroupID> = []
    // Billing and engagement stats per document.
    // Keyed by DocumentID — same identifier as the document itself.
    // Created when a document is registered; removed when it is deleted.
    var documentStats: [DocumentID : Database.DocumentStats] = [:]

    // Lanes: which app's slice of the index a document and a group live in. One
    // Thread serves every app; every read is cut to the caller's lane with these,
    // and a write lands in exactly one. A document has one lane for life (its
    // first filing); a group belongs to the lane that created it. Absent on a
    // Thread running open or for one app alone (everything is `LaneID.unscoped`).
    var documentLanes: [DocumentID : LaneID] = [:]
    var laneDocuments: [LaneID : Set<DocumentID>] = [:]
    var groupLanes: [GroupID : LaneID] = [:]
    var laneGroups: [LaneID : Set<GroupID>] = [:]

    init() {}
}

extension ThreadRegistry {
    struct Owner: Codable, Hashable {
        let id: String
    }
}

// MARK: - Modifications

extension ThreadRegistry {
    /// Removes an orphaned DocumentID — one whose file is missing on disk — from all
    /// registry collections without requiring a pre-fetched owner or group object.
    /// Safe to call during startup before the document cache is populated.
    ///
    /// PIN: crash recovery keeps the groups it empties. The sweeps that call this drop
    /// what a crash left half-written, and the client's re-index files those documents
    /// back into the same groups — with the label, access and metadata they held. Only
    /// an owner's own removal drops a group it leaves empty (`remove`, `removeGroup`).
    mutating func removeOrphaned(documentId: DocumentID) {
        let owners = documentOwners[documentId] ?? []
        for owner in owners {
            ownersDocuments[owner]?.removeAll(where: { $0 == documentId })
            ownerDocumentGroup[owner.id]?.removeValue(forKey: documentId)
        }
        for groupId in documentGroups[documentId] ?? [] {
            groups[groupId]?.removeAll(where: { $0 == documentId })
        }
        documentOwners.removeValue(forKey: documentId)
        documentGroups.removeValue(forKey: documentId)
        documentAccess.removeValue(forKey: documentId)
        documentStats.removeValue(forKey: documentId)
        availableDocumentIds.remove(documentId)
        detachLane(documentId: documentId)
    }

    /// Unlinks one owner from a document.
    /// Returns `true` when the document was fully removed (no owners remain)
    /// and the caller should delete the physical file, partition table entry, and HNSW nodes.
    /// Returns `false` when other owners still hold the document — only the personal
    /// HNSW entries for the removed owner should be cleaned up.
    ///
    /// The document leaves every group of the remover's that lists it — never another
    /// owner's — and a group it leaves with no documents goes with it (`unfile`).
    @discardableResult
    mutating func remove(
        documentId: DocumentID,
        group: Database.Group?,
        owner: Owner
    ) -> Bool {
        var ownerDocuments = self.ownersDocuments[owner] ?? []
        ownerDocuments.removeAll(where: { $0 == documentId })
        self.ownersDocuments[owner] = ownerDocuments

        // The remover's groups that hold the document: its own place for it (the
        // per-owner map is authoritative), and any other group of theirs listing it — a
        // document filed by the same owner under two groups is listed by both. The
        // caller's hint counts only when it is the remover's and holds the document.
        var held = Set((documentGroups[documentId] ?? []).filter { groupOwners[$0] == owner })
        if let own = ownerDocumentGroup[owner.id]?.removeValue(forKey: documentId) { held.insert(own) }
        if let hint = group?.id, groupOwners[hint] == owner, groups[hint]?.contains(documentId) == true {
            held.insert(hint)
        }
        for groupId in held.sorted() { unfile(documentId, from: groupId) }

        documentOwners[documentId]?.remove(owner)

        guard documentOwners[documentId]?.isEmpty != false else {
            return false  // other owners still hold this document
        }

        // Last owner removed — no group may keep listing it, and a group left with no
        // documents goes; then purge all remaining document-level state.
        for groupId in (documentGroups[documentId] ?? []).sorted() { unfile(documentId, from: groupId) }
        documentOwners.removeValue(forKey: documentId)
        documentGroups.removeValue(forKey: documentId)
        documentAccess.removeValue(forKey: documentId)
        documentStats.removeValue(forKey: documentId)
        availableDocumentIds.remove(documentId)
        detachLane(documentId: documentId)
        return true
    }

    /// Links a new owner (or a new group) to an already-indexed document without re-embedding.
    /// Idempotent — calling it twice for the same (documentId, ownerId, group) triple is safe.
    /// When the owner is already linked but the group is new, only the group associations are
    /// written — owner-level maps are left unchanged.
    ///
    /// Returns `false`, writing nothing, when the document lives in another lane: an app
    /// never gains a document another app filed, whatever its id says.
    @discardableResult
    mutating func linkOwner(documentId: DocumentID, ownerId: OwnerID, group: Database.Group?,
                            lane: LaneID = .unscoped) -> Bool {
        guard admits(documentId: documentId, lane: lane) else { return false }
        let owner = Owner(id: ownerId)
        let alreadyOwner = documentOwners[documentId]?.contains(owner) == true
        attachLane(documentId: documentId, lane: lane)

        if !alreadyOwner {
            documentOwners[documentId, default: []].insert(owner)

            var hashes = ownersDocuments[owner] ?? []
            if !hashes.contains(documentId) { hashes.append(documentId) }
            ownersDocuments[owner] = hashes
        }

        // Drop the group entirely if another owner — or another lane — already holds it:
        // don't write any group-keyed state (groups, ownerDocumentGroup, documentGroups,
        // ownersGroups).
        guard let group, groupOwners[group.id] == nil || groupOwners[group.id] == owner,
              admits(groupId: group.id, lane: lane) else { return true }
        let groupId = group.id
        attachLane(groupId: groupId, lane: lane)

        // Preserve the primary (first-registered) group in ownerDocumentGroup; additional
        // groups for the same (owner, document) pair are tracked only in documentGroups.
        if ownerDocumentGroup[ownerId]?[documentId] == nil {
            ownerDocumentGroup[ownerId, default: [:]][documentId] = groupId
        }
        documentGroups[documentId, default: []].insert(groupId)

        var groupHashes = groups[groupId] ?? []
        if !groupHashes.contains(documentId) { groupHashes.append(documentId) }
        groups[groupId] = groupHashes

        var groupOwnersHashes = ownersGroups[owner] ?? []
        if !groupOwnersHashes.contains(where: { $0.id == groupId }) {
            sortedGroupInsert(
                .init(id: group.id, label: group.label, ownerId: ownerId, documents: [], metadata: group.metadata),
                into: &groupOwnersHashes
            )
        }
        ownersGroups[owner] = groupOwnersHashes
        if groupOwners[groupId] == nil { groupOwners[groupId] = owner }

        if groupAccess[groupId] == nil { updateGroupAccess(for: groupId, state: group.access ?? .restricted) }
        return true
    }
}

// MARK: - Lanes

extension ThreadRegistry {
    /// The lane a document was filed under; `.unscoped` when none was recorded.
    func lane(of documentId: DocumentID) -> LaneID { documentLanes[documentId] ?? .unscoped }

    /// The lane a group was created in; `.unscoped` when none was recorded.
    func lane(ofGroup groupId: GroupID) -> LaneID { groupLanes[groupId] ?? .unscoped }

    /// Whether a caller in `lane` may touch `documentId`. An unscoped caller (a Thread
    /// with no lanes) may touch anything; otherwise the document must be unfiled or
    /// filed in that same lane.
    func admits(documentId: DocumentID, lane: LaneID) -> Bool {
        if lane.isUnscoped { return true }
        guard let existing = documentLanes[documentId] else { return true }
        return existing == lane
    }

    func admits(groupId: GroupID, lane: LaneID) -> Bool {
        if lane.isUnscoped { return true }
        guard let existing = groupLanes[groupId] else { return true }
        return existing == lane
    }

    /// The documents a caller in `lane` may read, or nil when nothing is cut (unscoped).
    func documents(inLane lane: LaneID) -> Set<DocumentID>? {
        lane.isUnscoped ? nil : (laneDocuments[lane] ?? [])
    }

    /// The groups a caller in `lane` may read, or nil when nothing is cut (unscoped).
    func groups(inLane lane: LaneID) -> Set<GroupID>? {
        lane.isUnscoped ? nil : (laneGroups[lane] ?? [])
    }

    /// Whether `documentId` is readable from `lane`.
    func isReadable(_ documentId: DocumentID, from lane: LaneID) -> Bool {
        guard let allowed = documents(inLane: lane) else { return true }
        return allowed.contains(documentId)
    }

    /// Whether `groupId` is readable from `lane`.
    func isGroupReadable(_ groupId: GroupID, from lane: LaneID) -> Bool {
        guard let allowed = groups(inLane: lane) else { return true }
        return allowed.contains(groupId)
    }

    /// The lanes, other than `lane`, that `documentIds` belong to. Empty means every
    /// document is the caller's (or unfiled). Graph admin's provenance rule.
    func foreignLanes(of documentIds: some Sequence<DocumentID>, outside lane: LaneID) -> Set<LaneID> {
        guard !lane.isUnscoped else { return [] }
        var foreign = Set<LaneID>()
        for id in documentIds {
            if let other = documentLanes[id], other != lane { foreign.insert(other) }
        }
        return foreign
    }

    /// Records a document's lane on its first filing. A lane is for life: a later
    /// filing from another lane is refused upstream (`admits`), never re-filed here.
    mutating func attachLane(documentId: DocumentID, lane: LaneID) {
        guard !lane.isUnscoped, documentLanes[documentId] == nil else { return }
        documentLanes[documentId] = lane
        laneDocuments[lane, default: []].insert(documentId)
    }

    mutating func attachLane(groupId: GroupID, lane: LaneID) {
        guard !lane.isUnscoped, groupLanes[groupId] == nil else { return }
        groupLanes[groupId] = lane
        laneGroups[lane, default: []].insert(groupId)
    }

    mutating func detachLane(documentId: DocumentID) {
        guard let lane = documentLanes.removeValue(forKey: documentId) else { return }
        laneDocuments[lane]?.remove(documentId)
        if laneDocuments[lane]?.isEmpty == true { laneDocuments.removeValue(forKey: lane) }
    }

    mutating func detachLane(groupId: GroupID) {
        guard let lane = groupLanes.removeValue(forKey: groupId) else { return }
        laneGroups[lane]?.remove(groupId)
        if laneGroups[lane]?.isEmpty == true { laneGroups.removeValue(forKey: lane) }
    }

    /// Takes `documentId` out of `groupId`'s list and the group out of the document's
    /// index; a group left with no documents is dropped. The one place a removal empties
    /// a group, so every path — a document removed, a batch, a move, RemoveGroups —
    /// drops it the same way.
    mutating func unfile(_ documentId: DocumentID, from groupId: GroupID) {
        if var listed = groups[groupId] {
            listed.removeAll(where: { $0 == documentId })
            groups[groupId] = listed
        }
        documentGroups[documentId]?.remove(groupId)
        if documentGroups[documentId]?.isEmpty == true {
            documentGroups.removeValue(forKey: documentId)
        }
        dropIfEmpty(groupId)
    }

    /// A group exists while it holds documents: an owned group with none is dropped.
    mutating func dropIfEmpty(_ groupId: GroupID) {
        guard groupOwners[groupId] != nil, (groups[groupId] ?? []).isEmpty else { return }
        removeGroupRecord(groupId)
    }

    /// Deletes `groupId` for its owner — RemoveGroups' registry half. Each document filed
    /// in it leaves it:
    /// - the owner holds it in no other group of theirs → the owner is unlinked from it,
    ///   and it is fully removed when the owner was its last;
    /// - the owner also filed it under another group → it stays, there;
    /// - the owner does not hold it → its id is only taken out of the list.
    /// Then the group's record goes, also when it was empty to begin with. Returns the
    /// documents unlinked from the owner, and those of them fully removed (for the caller
    /// to purge). The caller checks the owner and the lane; another owner's group is left.
    mutating func removeGroup(_ groupId: GroupID, owner: Owner) -> (unlinked: [DocumentID], fullyRemoved: [DocumentID]) {
        guard groupOwners[groupId] == owner else { return ([], []) }
        var unlinked: [DocumentID] = []
        var fullyRemoved: [DocumentID] = []
        for documentId in groups[groupId] ?? [] {
            let holds = documentOwners[documentId]?.contains(owner) == true
            let elsewhere = (documentGroups[documentId] ?? []).first { $0 != groupId && groupOwners[$0] == owner }
            if holds, elsewhere == nil {
                unlinked.append(documentId)
                if remove(documentId: documentId, group: nil, owner: owner) { fullyRemoved.append(documentId) }
            } else {
                if holds, let elsewhere, ownerDocumentGroup[owner.id]?[documentId] == groupId {
                    ownerDocumentGroup[owner.id]?[documentId] = elsewhere
                }
                unfile(documentId, from: groupId)
            }
        }
        removeGroupRecord(groupId)
        return (unlinked, fullyRemoved)
    }

    /// Drops every record of a group: its document list, owner, access, lane and the
    /// owner's entry for it. Documents are left to their own removal.
    mutating func removeGroupRecord(_ groupId: GroupID) {
        if let owner = groupOwners[groupId] {
            var ownerGroups = ownersGroups[owner] ?? []
            ownerGroups.removeAll(where: { $0.id == groupId })
            ownersGroups[owner] = ownerGroups
        }
        groups.removeValue(forKey: groupId)
        groupOwners.removeValue(forKey: groupId)
        groupAccess.removeValue(forKey: groupId)
        availableGroupIds.remove(groupId)
        detachLane(groupId: groupId)
    }
}

// MARK: - Document Stats

extension ThreadRegistry {
    /// Returns the stats for a given document, or a zero-value default if absent.
    func stats(for documentId: DocumentID) -> Database.DocumentStats {
        documentStats[documentId] ?? .init(id: documentId)
    }

    /// Accumulates credits earned into the stats entry for each document.
    /// Creates a new stats entry when one does not yet exist.
    mutating func addEarnings(_ earnings: [DocumentID: Gita.Credits]) {
        for (documentId, credits) in earnings where credits > 0 {
            documentStats[documentId, default: .init(id: documentId)].totalEarned += credits
        }
    }

    /// Additively merges per-document performance updates from a `Sinatra.PrepareResult`
    /// into the registry's `documentStats` map.
    mutating func addPerformance(_ updates: [DocumentID: Database.DocumentStats]) {
        for (documentId, updated) in updates {
            var entry = documentStats[documentId, default: .init(id: documentId)]
            entry.retrievalCount += updated.retrievalCount
            entry.sentimentSum   += updated.sentimentSum
            if let t = updated.lastRetrieved {
                entry.lastRetrieved = t
            }
            for (partitionId, count) in updated.partitionRetrievalCount {
                entry.partitionRetrievalCount[partitionId, default: 0] += count
            }
            for (partitionId, ps) in updated.partitionSentiments {
                entry.partitionSentiments[partitionId, default: .init()].retrievalCount += ps.retrievalCount
                entry.partitionSentiments[partitionId, default: .init()].sentimentSum   += ps.sentimentSum
                if let t = ps.lastRetrieved {
                    entry.partitionSentiments[partitionId, default: .init()].lastRetrieved = t
                }
            }
            documentStats[documentId] = entry
        }
    }

    /// Returns the total credits earned across all documents in a group.
    func totalEarnings(for groupId: GroupID) -> Gita.Credits {
        let documentIds = groups[groupId] ?? []
        return documentIds.reduce(0) { $0 + (documentStats[$1]?.totalEarned ?? 0) }
    }
}

// MARK: - Access

extension ThreadRegistry {
    enum Access: String, Codable {
        case available
        case restricted
        case unknown
    }

    func getDocumentAccess(_ id: DocumentID) -> Access {
        documentAccess[id] ?? .unknown
    }

    /// Updates the availability/access state for a document.
    /// Also keeps `availableDocumentIds` in sync so global-scope queries
    /// never need to scan `documentAccess`.
    mutating func updateDocumentAccess(for id: DocumentID, state: Access) {
        documentAccess[id] = state
        if state == .available {
            availableDocumentIds.insert(id)
        } else {
            availableDocumentIds.remove(id)
        }
    }

    /// Checks if document exists in the registry (has at least one owner).
    func doesDocumentExist(_ documentId: DocumentID) -> Bool {
        if let state = documentAccess[documentId] {
            return state != .unknown
        } else {
            return false
        }
    }

    /// Returns `true` when `ownerId` is among the linked owners of `documentId`.
    func isOwnerLinked(_ documentId: DocumentID, ownerId: OwnerID) -> Bool {
        documentOwners[documentId]?.contains(Owner(id: ownerId)) == true
    }
}

extension ThreadRegistry {
    func getGroupAccess(_ id: GroupID) -> Access {
        groupAccess[id] ?? .unknown
    }

    mutating func updateGroupAccess(for id: GroupID, state: Access) {
        groupAccess[id] = state
        if state == .available {
            availableGroupIds.insert(id)
        } else {
            availableGroupIds.remove(id)
        }
    }
}

// MARK: - Helpers

private func sortedGroupInsert(_ group: Database.Group, into list: inout [Database.Group]) {
    var lo = 0, hi = list.count
    while lo < hi {
        let mid = (lo + hi) / 2
        if list[mid].id < group.id { lo = mid + 1 } else { hi = mid }
    }
    list.insert(group, at: lo)
}

extension ThreadRegistry {
    /// Returns a `Database.Group` for a document using the first group in the Set index.
    /// Prefer `ownerDocumentGroup[ownerId]?[documentId]` for owner-scoped lookups.
    func group(for documentId: DocumentID) -> Database.Group? {
        guard let groupId = documentGroups[documentId]?.first else { return nil }
        guard let owner = groupOwners[groupId] else { return nil }
        return ownersGroups[owner]?.first(where: { $0.id == groupId })
    }
}

// MARK: - Pure mutations

extension ThreadRegistry {
    /// Registers `documentId` under `ownerId` with an optional group association.
    ///
    /// `RegistryMutator.register`'s registry half. Does not touch caches, actors,
    /// or persistence — pure in-memory mutation.
    mutating func applyRegister(documentId: DocumentID, ownerId: OwnerID, group: Database.Group?,
                                lane: LaneID = .unscoped) {
        let owner = Owner(id: ownerId)

        documentOwners[documentId, default: []].insert(owner)
        attachLane(documentId: documentId, lane: lane)

        var hashes = ownersDocuments[owner] ?? []
        if !hashes.contains(documentId) { hashes.append(documentId) }
        ownersDocuments[owner] = hashes

        if documentStats[documentId] == nil {
            documentStats[documentId] = .init(id: documentId)
        }

        let effectiveGroup: Database.Group? = {
            guard let g = group else { return nil }
            let existing = groupOwners[g.id]
            guard existing == nil || existing == owner else { return nil }
            // A group created in another lane is another app's: the document is filed
            // without a group rather than into it.
            return admits(groupId: g.id, lane: lane) ? g : nil
        }()

        if let g = effectiveGroup {
            let groupId = g.id
            attachLane(groupId: groupId, lane: lane)
            var groupHashes = groups[groupId] ?? []
            if !groupHashes.contains(documentId) { groupHashes.append(documentId) }
            groups[groupId] = groupHashes
            ownerDocumentGroup[ownerId, default: [:]][documentId] = groupId
            documentGroups[documentId, default: []].insert(groupId)

            var ownerGroupList = ownersGroups[owner] ?? []
            if let existingIdx = ownerGroupList.firstIndex(where: { $0.id == groupId }) {
                // Merge new tags into an existing group's metadata.
                if let newTags = g.metadata?.tags, !newTags.isEmpty {
                    var existingMeta = ownerGroupList[existingIdx].metadata ?? Database.Group.Metadata()
                    existingMeta.tags = Array(Set(existingMeta.tags + newTags)).sorted()
                    ownerGroupList[existingIdx].metadata = existingMeta
                    ownersGroups[owner] = ownerGroupList
                }
            } else {
                sortedGroupInsert(
                    .init(id: g.id, label: g.label, ownerId: ownerId, documents: [], metadata: g.metadata),
                    into: &ownerGroupList
                )
                ownersGroups[owner] = ownerGroupList
            }
            if groupOwners[groupId] == nil { groupOwners[groupId] = owner }
            if groupAccess[groupId] == nil { updateGroupAccess(for: groupId, state: g.access ?? .restricted) }
            if let access = groupAccess[groupId] { updateDocumentAccess(for: documentId, state: access) }
        } else {
            updateDocumentAccess(for: documentId, state: .restricted)
        }
    }
}
