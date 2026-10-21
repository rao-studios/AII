//
//  RegistryMutator.swift
//  Thread
//
//  Created by Ritesh Pakala on 03/13/26.
//  Copyright © 2026 Rao Studios LLC.
//

import AII
import Foundation

/// Serializes all read-modify-write operations on the ThreadRegistry file.
///
/// Without this actor, concurrent embedding requests each load the same registry
/// state, apply their mutations locally, and save — last write wins, silently
/// dropping every other concurrent registration. Groups and documents registered
/// in the "lost" writes disappear without any purge being called.
///
/// Mirrors `TableMutator`: every method that mutates the registry must go through
/// this actor so each operation sees the full result of the previous one.
///
/// Lanes: every mutation that files or touches a document takes the caller's lane
/// (`LaneID.unscoped` on a Thread with no lanes). A document in another lane is
/// never registered to, linked, removed or regrouped — the registry's own rule
/// (`ThreadRegistry.admits`), so no caller can get around it.
actor RegistryMutator {
    private let cache: ThreadCache<ThreadRegistry>
    private let logger: ThreadLogger

    /// Bumped on every committed mutation; the lane-stats cache keys on it.
    private let version = LockedValue<UInt64>(0)

    // MARK: - Debounced disk saves

    private var registryDirty = false
    private var flushTask: Task<Void, Never>?

    /// The registry is node-scoped (`registry-<nodeId>`), like the table and
    /// graph. A single shared `registry` file let every co-located node's boot
    /// sweeps treat the other nodes' documents as orphans — each restart
    /// reaped every other node's registrations.
    init(nodeId: UUID, logger: ThreadLogger) {
        self.cache = ThreadCache(
            persistence: FilePersistence(key: "registry-\(nodeId)", kind: .basic, logger: logger.base)
        )
        self.logger = logger
    }

    // MARK: - Startup seeding

    /// Seeds the lock-protected snapshot synchronously at startup — no actor hop required.
    nonisolated func seed(_ initial: ThreadRegistry) {
        cache.seed(initial)
        version.withLock { $0 &+= 1 }
    }

    // MARK: - Snapshot

    /// Synchronous, lock-protected read of the latest registry state.
    /// Never hops the actor queue — safe to call from any context.
    nonisolated var snapshot: ThreadRegistry? { cache.snapshot }

    /// How many mutations have been committed; changes whenever the snapshot does.
    nonisolated var mutationVersion: UInt64 { version.withLock { $0 } }

    // MARK: - Private

    private func loadedRegistry() async -> ThreadRegistry {
        return await cache.load { .init() }
    }

    /// Publishes a mutated registry to the snapshot and counts the mutation.
    private func commit(_ registry: ThreadRegistry) {
        cache.update(registry)
        version.withLock { $0 &+= 1 }
    }

    /// Persists the complete registry to disk now. Cold-path mutations (remove, access
    /// update, group rename) call this so their durability does not wait on the debounce.
    private func persistNow() {
        guard let registry = cache.snapshot else { return }
        registryDirty = false
        flushTask?.cancel()
        flushTask     = nil
        Task { await self.cache.saveNow(registry) }
    }

    /// Wipes this node's registry and persists the empty state immediately.
    func clearAll() async {
        flushTask?.cancel()
        flushTask = nil
        registryDirty = false
        let empty = ThreadRegistry()
        commit(empty)
        await cache.saveNow(empty)
    }

    /// Durably flushes the registry to disk. Call from `Database.shutdown()`.
    func flushForShutdown() async {
        guard let registry = cache.snapshot else { return }
        await cache.saveNow(registry)
        registryDirty = false
        flushTask?.cancel()
        flushTask     = nil
    }

    private func scheduleSave() {
        registryDirty = true
        guard flushTask == nil else { return }
        flushTask = Task {
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
            self.flushIfDirty()
        }
    }

    private func flushIfDirty() {
        guard registryDirty, let registry = cache.snapshot else {
            flushTask = nil
            return
        }
        cache.saveAsync(registry)
        registryDirty = false
        flushTask = nil
    }

    // MARK: - Register

    func register(
        _ document: Database.Document,
        group: Database.Group?,
        ownerId: String,
        lane: LaneID = .unscoped
    ) async {
        var registry = await loadedRegistry()
        guard registry.admits(documentId: document.id, lane: lane) else {
            logger.warning("Registry: refused to register \(document.id) — it belongs to lane \(registry.lane(of: document.id))", service: .database)
            return
        }
        registry.applyRegister(documentId: document.id, ownerId: ownerId, group: group, lane: lane)
        commit(registry)
        scheduleSave()
    }

    /// Registers multiple documents in a single actor invocation.
    /// Loads the registry once, applies all mutations, then schedules one debounced save.
    /// Returns the ids that were refused because they live in another lane.
    @discardableResult
    func registerBatch(items: [(document: Database.Document, group: Database.Group?, ownerId: String)],
                       lane: LaneID = .unscoped) async -> [DocumentID] {
        var registry = await loadedRegistry()
        var refused: [DocumentID] = []
        for (document, group, ownerId) in items {
            guard registry.admits(documentId: document.id, lane: lane) else {
                refused.append(document.id)
                continue
            }
            registry.applyRegister(documentId: document.id, ownerId: ownerId, group: group, lane: lane)
        }
        commit(registry)
        scheduleSave()
        return refused
    }

    // MARK: - Link Owner

    /// Links a new owner to an already-indexed document without re-embedding.
    /// The physical document, vectors, and partition table entry are shared as-is.
    /// Returns `false` when the document belongs to another lane (nothing is written).
    @discardableResult
    func linkOwner(documentId: DocumentID, group: Database.Group?, ownerId: String,
                   lane: LaneID = .unscoped) async -> Bool {
        var registry = await loadedRegistry()
        let linked = registry.linkOwner(documentId: documentId, ownerId: ownerId, group: group, lane: lane)
        guard linked else { return false }
        commit(registry)
        scheduleSave()
        return true
    }

    /// Links multiple new owners to existing documents in a single actor invocation.
    /// Returns the ids refused for living in another lane.
    @discardableResult
    func linkOwnerBatch(items: [(documentId: DocumentID, group: Database.Group?, ownerId: String)],
                        lane: LaneID = .unscoped) async -> [DocumentID] {
        guard !items.isEmpty else { return [] }
        var registry = await loadedRegistry()
        var refused: [DocumentID] = []
        for (documentId, group, ownerId) in items {
            if !registry.linkOwner(documentId: documentId, ownerId: ownerId, group: group, lane: lane) {
                refused.append(documentId)
            }
        }
        commit(registry)
        scheduleSave()
        return refused
    }

    // MARK: - Remove

    /// Unlinks one owner from a document.
    /// Returns `(authorized: true, fullyRemoved: true)` when the caller was the last
    /// owner and the document should be physically deleted (file, table, HNSW).
    /// Returns `(authorized: true, fullyRemoved: false)` when other owners remain —
    /// only the caller's personal HNSW entries need to be cleaned up.
    /// Returns `(authorized: false, ...)` when the caller does not own the document,
    /// or the document is another lane's.
    func remove(
        documentId: DocumentID,
        group: Database.Group?,
        ownerId: String,
        lane: LaneID = .unscoped
    ) async -> (authorized: Bool, fullyRemoved: Bool) {
        var registry = await loadedRegistry()
        let owner = ThreadRegistry.Owner(id: ownerId)
        guard registry.documentOwners[documentId]?.contains(owner) == true,
              registry.isReadable(documentId, from: lane) else {
            return (false, false)
        }
        let fullyRemoved = registry.remove(documentId: documentId, group: group, owner: owner)
        commit(registry)
        persistNow()
        return (true, fullyRemoved)
    }

    // MARK: - Remove All

    /// Unlinks `ownerId` from all their documents in `lane` (every lane when unscoped).
    /// Owners are shared across apps — one signed-in account owns documents in each
    /// lane — so a lane is required to keep one app's wipe from taking another's.
    /// Returns:
    ///   - `fullyRemoved`: document IDs where this owner was the last — callers should
    ///     delete the physical file and partition table entry.
    ///   - `allOwned`: every document ID the owner had in the lane (superset of
    ///     `fullyRemoved`) — callers should remove all from the personal HNSW.
    func removeAll(ownerId: String, lane: LaneID = .unscoped) async -> (fullyRemoved: [DocumentID], allOwned: [DocumentID]) {
        var registry = await loadedRegistry()
        let owner = ThreadRegistry.Owner(id: ownerId)
        let documentIds = (registry.ownersDocuments[owner] ?? []).filter { registry.isReadable($0, from: lane) }
        let ownedGroupIds = (registry.ownersGroups[owner] ?? []).map { $0.id }
            .filter { registry.isGroupReadable($0, from: lane) }

        var fullyRemoved: [DocumentID] = []
        for documentId in documentIds {
            let wasLast = registry.remove(documentId: documentId, group: nil, owner: owner)
            if wasLast { fullyRemoved.append(documentId) }
        }

        for groupId in ownedGroupIds {
            registry.removeGroupRecord(groupId)
        }

        if registry.ownersDocuments[owner]?.isEmpty == true { registry.ownersDocuments.removeValue(forKey: owner) }
        if registry.ownersGroups[owner]?.isEmpty == true { registry.ownersGroups.removeValue(forKey: owner) }
        if registry.ownerDocumentGroup[ownerId]?.isEmpty == true { registry.ownerDocumentGroup.removeValue(forKey: ownerId) }

        commit(registry)
        persistNow()
        return (fullyRemoved, documentIds)
    }

    /// Unlinks a specific set of (documentId, ownerId) pairs in a single actor
    /// invocation. Returns the IDs that were fully removed (last owner gone).
    /// Pairs naming another lane's document are skipped.
    @discardableResult
    func removeBatch(
        items: [(documentId: DocumentID, ownerId: String)],
        lane: LaneID = .unscoped
    ) async -> [DocumentID] {
        _ = await loadedRegistry()
        var registry = cache.snapshot ?? ThreadRegistry()
        var fullyRemoved: [DocumentID] = []
        for (documentId, ownerId) in items {
            let owner = ThreadRegistry.Owner(id: ownerId)
            guard registry.documentOwners[documentId]?.contains(owner) == true,
                  registry.isReadable(documentId, from: lane) else { continue }
            let wasLast = registry.remove(documentId: documentId, group: nil, owner: owner)
            if wasLast { fullyRemoved.append(documentId) }
        }
        commit(registry)
        persistNow()
        return fullyRemoved
    }

    /// Removes every document and group of one lane, whoever owns them: a lane clear.
    /// Returns the document ids removed (all of them were the lane's alone, so each is
    /// fully removed) so the caller can purge files, table entries and graph provenance.
    func removeLane(_ lane: LaneID) async -> [DocumentID] {
        guard !lane.isUnscoped else { return [] }
        var registry = await loadedRegistry()
        let documentIds = Array(registry.laneDocuments[lane] ?? [])
        for documentId in documentIds {
            for owner in registry.documentOwners[documentId] ?? [] {
                registry.remove(documentId: documentId, group: nil, owner: owner)
            }
            // A document whose owners are all gone is purged by `remove`; one that
            // somehow had none is dropped here.
            if registry.documentOwners[documentId] != nil { registry.removeOrphaned(documentId: documentId) }
        }
        for groupId in Array(registry.laneGroups[lane] ?? []) {
            registry.removeGroupRecord(groupId)
        }
        // Owners left with nothing in any lane drop out of the owner maps.
        for owner in Array(registry.ownersDocuments.keys) where registry.ownersDocuments[owner]?.isEmpty == true
            && (registry.ownersGroups[owner]?.isEmpty ?? true) {
            registry.ownersDocuments.removeValue(forKey: owner)
            registry.ownersGroups.removeValue(forKey: owner)
            registry.ownerDocumentGroup.removeValue(forKey: owner.id)
        }
        commit(registry)
        persistNow()
        return documentIds
    }

    // MARK: - Document Stats

    /// Accumulates credit earnings into the `documentStats` map for each document in
    /// `earnings`. Appends a WAL record so the full registry is not rewritten.
    func accumulateEarnings(_ earnings: [DocumentID: Gita.Credits]) async {
        guard !earnings.isEmpty else { return }
        var registry = await loadedRegistry()
        registry.addEarnings(earnings)
        commit(registry)
        scheduleSave()
    }

    /// Merges per-document performance updates from a `Sinatra.PrepareResult` into
    /// `documentStats`, then schedules a debounced save.
    func accumulatePerformance(_ updates: [DocumentID: Database.DocumentStats]) async {
        guard !updates.isEmpty else { return }
        var registry = await loadedRegistry()
        registry.addPerformance(updates)
        commit(registry)
        scheduleSave()
    }

    // MARK: - Access

    @discardableResult
    func updateDocumentAccess(id: String, ownerId: String, access: ThreadRegistry.Access,
                              lane: LaneID = .unscoped) async -> Bool {
        var registry = await loadedRegistry()
        guard registry.documentOwners[id]?.contains(ThreadRegistry.Owner(id: ownerId)) == true,
              registry.isReadable(id, from: lane) else { return false }
        registry.updateDocumentAccess(for: id, state: access)
        commit(registry)
        persistNow()
        return true
    }

    @discardableResult
    func updateGroupAccess(id: String, ownerId: String, access: ThreadRegistry.Access,
                           lane: LaneID = .unscoped) async -> Bool {
        var registry = await loadedRegistry()
        guard registry.groupOwners[id]?.id == ownerId, registry.isGroupReadable(id, from: lane) else { return false }
        registry.updateGroupAccess(for: id, state: access)
        let documents = registry.groups[id] ?? []
        for documentId in documents {
            registry.updateDocumentAccess(for: documentId, state: access)
        }
        commit(registry)
        persistNow()
        return true
    }

    /// Replaces the entire in-memory cache and checkpoints immediately.
    func replace(with registry: ThreadRegistry) {
        commit(registry)
        persistNow()
    }

    @discardableResult
    func updateGroup(_ group: Database.Group, documentId: String, ownerId: String,
                     lane: LaneID = .unscoped) async -> Bool {
        let id = group.id
        var registry = await loadedRegistry()
        let owner = ThreadRegistry.Owner(id: ownerId)
        guard registry.documentOwners[documentId]?.contains(owner) == true,
              registry.isReadable(documentId, from: lane),
              registry.admits(groupId: id, lane: lane) else { return false }

        // The mover's own group for the document — never another owner's.
        let oldGroupId = registry.ownerDocumentGroup[ownerId]?[documentId]
            ?? registry.documentGroups[documentId]?.first(where: { registry.groupOwners[$0] == owner })

        registry.ownerDocumentGroup[ownerId, default: [:]][documentId] = id
        if let oldGroupId {
            registry.documentGroups[documentId]?.remove(oldGroupId)
            if registry.documentGroups[documentId]?.isEmpty == true {
                registry.documentGroups.removeValue(forKey: documentId)
            }
        }
        registry.documentGroups[documentId, default: []].insert(id)

        if let oldGroupId {
            var oldGroupHashes = registry.groups[oldGroupId] ?? []
            oldGroupHashes.removeAll(where: { $0 == documentId })
            registry.groups[oldGroupId] = oldGroupHashes
        }
        let isNewGroup = registry.groupOwners[id] == nil
        var newGroupHashes = registry.groups[id] ?? []
        if !newGroupHashes.contains(documentId) { newGroupHashes.append(documentId) }
        registry.groups[id] = newGroupHashes

        if isNewGroup {
            registry.groupOwners[id] = owner
            registry.groupAccess[id] = group.access ?? .restricted
            registry.attachLane(groupId: id, lane: lane)
            var ownerGroups = registry.ownersGroups[owner] ?? []
            var lo = 0, hi = ownerGroups.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if ownerGroups[mid].id < group.id { lo = mid + 1 } else { hi = mid }
            }
            ownerGroups.insert(
                .init(id: group.id, label: group.label, ownerId: group.ownerId, documents: [], metadata: group.metadata),
                at: lo
            )
            registry.ownersGroups[owner] = ownerGroups
            logger.info("Registry", "New group detected, creating records.", service: .database)
        }
        // The group the document left goes when it holds nothing now.
        if let oldGroupId, oldGroupId != id { registry.dropIfEmpty(oldGroupId) }

        commit(registry)
        persistNow()
        return true
    }

    /// Updates the metadata for a group. Returns `false` if the caller does not own the group.
    @discardableResult
    func updateGroupMetadata(id: String, ownerId: OwnerID, metadata: Database.Group.Metadata,
                             lane: LaneID = .unscoped) async -> Bool {
        var registry = await loadedRegistry()
        let owner = ThreadRegistry.Owner(id: ownerId)
        guard registry.groupOwners[id]?.id == ownerId, registry.isGroupReadable(id, from: lane) else { return false }

        var ownerGroups = registry.ownersGroups[owner] ?? []
        guard let idx = ownerGroups.firstIndex(where: { $0.id == id }) else { return false }
        ownerGroups[idx].metadata = metadata
        registry.ownersGroups[owner] = ownerGroups

        commit(registry)
        persistNow()
        return true
    }

    /// Renames a group. Returns `false` if the caller does not own the group.
    @discardableResult
    func renameGroup(id: String, ownerId: String, label: String, lane: LaneID = .unscoped) async -> Bool {
        var registry = await loadedRegistry()
        let owner = ThreadRegistry.Owner(id: ownerId)
        guard registry.groupOwners[id]?.id == ownerId, registry.isGroupReadable(id, from: lane) else { return false }

        var ownerGroups = registry.ownersGroups[owner] ?? []
        guard let idx = ownerGroups.firstIndex(where: { $0.id == id }) else { return false }
        ownerGroups[idx].label = label
        registry.ownersGroups[owner] = ownerGroups

        commit(registry)
        persistNow()
        return true
    }

    /// Deletes the groups `ownerId` owns in `lane` — what is filed in each, then the group
    /// (`ThreadRegistry.removeGroup`), also one already empty. A group of another owner or
    /// another lane is left alone and not reported. The caller purges the fully removed
    /// documents' files, table rows and graph links.
    func removeGroups(_ groupIds: [GroupID], ownerId: String, lane: LaneID = .unscoped) async -> Database.GroupRemoval {
        var removal = Database.GroupRemoval()
        guard !groupIds.isEmpty else { return removal }
        var registry = await loadedRegistry()
        let owner = ThreadRegistry.Owner(id: ownerId)
        var seen = Set<GroupID>()
        for groupId in groupIds where seen.insert(groupId).inserted {
            guard registry.groupOwners[groupId] == owner, registry.isGroupReadable(groupId, from: lane) else { continue }
            let (unlinked, fullyRemoved) = registry.removeGroup(groupId, owner: owner)
            removal.groups.append(groupId)
            removal.unlinked += unlinked
            removal.fullyRemoved += fullyRemoved
        }
        guard !removal.groups.isEmpty else { return removal }
        commit(registry)
        persistNow()
        return removal
    }
}
