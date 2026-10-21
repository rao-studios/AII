//
//  Database+Registry.swift
//  Thread
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//

import AII
import Foundation

extension Database {
    func initializeRegistry() {
        let storage = registryStore
        // This node's own registry; a file that is absent or no longer decodes starts fresh.
        var registry: ThreadRegistry = storage.restore() ?? .init()

        let allDocumentIds = Array(registry.documentOwners.keys)
        var initial: [DocumentID: Database.Document] = [:]
        var orphanedIds: [DocumentID] = []

        for documentId in allDocumentIds {
            let store = documentStore(for: documentId)
            guard FileManager.default.fileExists(atPath: store.url.path(percentEncoded: false)) else {
                orphanedIds.append(documentId)
                continue
            }
            if let document: Database.Document = store.restore() {
                initial[documentId] = document
            } else {
                orphanedIds.append(documentId)
            }
        }

        if !orphanedIds.isEmpty {
            for id in orphanedIds { registry.removeOrphaned(documentId: id) }
            storage.save(state: registry)
            logger.info(
                "Registry Init",
                "⚠️ Removed \(orphanedIds.count) orphaned document(s)",
                service: .database
            )
        }

        var staleGroupCount = 0
        for (owner, ownerGroups) in registry.ownersGroups {
            let cleaned = ownerGroups.filter { registry.groupOwners[$0.id] == owner }
            if cleaned.count != ownerGroups.count {
                staleGroupCount += ownerGroups.count - cleaned.count
                registry.ownersGroups[owner] = cleaned
            }
        }
        if staleGroupCount > 0 {
            storage.save(state: registry)
            logger.warning(
                "⚠️ Removed \(staleGroupCount) stale group reference(s) from ownersGroups",
                service: .database
            )
        }

        // Enforce sorted invariant on load. Write paths maintain this order, so
        // Timsort detects the existing runs in O(n).
        for key in registry.ownersGroups.keys {
            registry.ownersGroups[key]?.sort { $0.id < $1.id }
        }

        registryMutator.seed(registry)
        documentCache.seed(initial)
        logger.debug(
            "Registry Init",
            "⚜️ Database Registry initialized — \(allDocumentIds.count - orphanedIds.count) document(s) pre-cached",
            service: .database
        )
    }

    var registryStore: FilePersistence {
        FilePersistence(key: "registry-\(nodeId)", kind: .basic, logger: logger.base)
    }
}

extension Database {
    func register(_ document: Database.Document,
                  group: Database.Group?,
                  update: DatabaseUpdate? = nil,
                  ownerId: String,
                  lane: LaneID = .unscoped) async {
        await registryMutator.register(document, group: group, ownerId: ownerId, lane: lane)

        if let update, update.operation == .remove {
            await remove(documentId: update.documentId, group: group, ownerId: ownerId, lane: lane)
        }
    }

    @discardableResult
    func updateDocumentAccess(_ id: String,
                              ownerId: String,
                              access: ThreadRegistry.Access,
                              lane: LaneID = .unscoped) async -> Bool {
        let updated = await registryMutator.updateDocumentAccess(id: id, ownerId: ownerId, access: access, lane: lane)
        if !updated {
            logger.info("Registry", "Owner does not own this document.", service: .database)
        }
        return updated
    }
}

extension Database {
    /// The owner's groups in `lane` (every lane when unscoped), with their documents.
    nonisolated func groups(for ownerId: OwnerID, lane: LaneID = .unscoped) -> [Database.Group] {
        guard let registry else { return [] }
        let owner = ThreadRegistry.Owner(id: ownerId)
        return (registry.ownersGroups[owner] ?? []).compactMap { entry in
            guard entry.ownerId == owner.id, registry.isGroupReadable(entry.id, from: lane) else { return nil }
            return buildGroup(entry: entry, registry: registry)
        }
    }

    nonisolated func availableGroups(lane: LaneID = .unscoped) -> [Database.Group] {
        guard let registry else { return [] }
        return registry.availableGroupIds
            .filter { registry.isGroupReadable($0, from: lane) }
            .compactMap { buildGroup(groupId: $0, registry: registry) }
    }

    /// Returns lightweight group entries (documents NOT loaded) for the given owner,
    /// cut to `lane`. Useful for pagination: apply cursor/limit to the entries, then
    /// buildGroup only on the page.
    nonisolated func groupEntries(for ownerId: OwnerID, lane: LaneID = .unscoped) -> [Database.Group] {
        guard let registry else { return [] }
        let owner = ThreadRegistry.Owner(id: ownerId)
        return (registry.ownersGroups[owner] ?? []).filter {
            $0.ownerId == owner.id && registry.isGroupReadable($0.id, from: lane)
        }
    }

    /// Returns lightweight group entries for all available (public) groups in `lane`.
    nonisolated func availableGroupEntries(lane: LaneID = .unscoped) -> [Database.Group] {
        guard let registry else { return [] }
        return registry.availableGroupIds.filter { registry.isGroupReadable($0, from: lane) }.compactMap { id in
            guard let owner = registry.groupOwners[id],
                  let list = registry.ownersGroups[owner] else { return nil }
            var lo = 0, hi = list.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if list[mid].id < id { lo = mid + 1 }
                else if list[mid].id > id { hi = mid }
                else { return list[mid] }
            }
            return nil
        }
    }

    func stats(for documentId: DocumentID) -> Database.DocumentStats? {
        registry?.documentStats[documentId]
    }

    @discardableResult
    func updateGroupAccess(_ id: String,
                           ownerId: String,
                           access: ThreadRegistry.Access,
                           lane: LaneID = .unscoped) async -> Bool {
        let updated = await registryMutator.updateGroupAccess(id: id, ownerId: ownerId, access: access, lane: lane)
        if !updated {
            logger.info("Registry", "Owner does not own this group.", service: .database)
        }
        return updated
    }

    @discardableResult
    func renameGroup(id: String, ownerId: String, label: String, lane: LaneID = .unscoped) async -> Bool {
        await registryMutator.renameGroup(id: id, ownerId: ownerId, label: label, lane: lane)
    }

    @discardableResult
    func updateGroupMetadata(id: String, ownerId: String, metadata: Database.Group.Metadata,
                             lane: LaneID = .unscoped) async -> Bool {
        await registryMutator.updateGroupMetadata(id: id, ownerId: ownerId, metadata: metadata, lane: lane)
    }

    @discardableResult
    func updateGroup(_ group: Database.Group, documentId: String, ownerId: String,
                     lane: LaneID = .unscoped) async -> Bool {
        await registryMutator.updateGroup(group, documentId: documentId, ownerId: ownerId, lane: lane)
    }

    nonisolated var registry: ThreadRegistry? { registryMutator.snapshot }

    nonisolated func coOwners(for documentIds: some Collection<DocumentID>) -> [DocumentID: Set<OwnerID>] {
        guard let reg = registry else { return [:] }
        return documentIds.reduce(into: [:]) { result, docId in
            var owners = Set(reg.documentOwners[docId]?.map(\.id) ?? [])
            for groupId in reg.documentGroups[docId] ?? [] {
                if let groupOwner = reg.groupOwners[groupId] {
                    owners.insert(groupOwner.id)
                }
            }
            guard owners.count > 1 else { return }
            result[docId] = owners
        }
    }
}
