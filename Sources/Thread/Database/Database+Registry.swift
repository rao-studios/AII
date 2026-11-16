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
        let root = FilePersistence.getDefaultURL()
        // A flat documents/ folder (every document's files in one folder) is set aside with one
        // rename before any document is read: DocumentFiles.
        DocumentFiles.setFlatAside(root: root, logger: logger.base)

        let storage = registryStore
        // This node's own registry; a file that is absent or no longer decodes starts fresh.
        var registry: ThreadRegistry = storage.restore() ?? .init()

        let allDocumentIds = Array(registry.documentOwners.keys)
        var initial: [DocumentID: Database.Document] = [:]
        var missing: [DocumentID] = []

        // One look per document in its shard: restore() answers nil for a file that is not there.
        for documentId in allDocumentIds {
            if let document: Database.Document = documentStore(for: documentId).restore() {
                initial[documentId] = document
            } else {
                missing.append(documentId)
            }
        }

        // A document missed in its shard may still be in a flat folder set aside: copied in by name.
        let (adopted, orphanedIds) = adoptFlatDocuments(missing, root: root)
        initial.merge(adopted) { current, _ in current }

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

    /// Copies each of `ids` from a flat folder set aside into its shard, eight at a time (each
    /// copy waits on the disk, not the CPU), and restores it. Answers the documents restored and
    /// the ids found nowhere; an id whose file is there but could not be copied is in neither,
    /// so it stays registered for the next start.
    private nonisolated func adoptFlatDocuments(
        _ ids: [DocumentID], root: URL
    ) -> (adopted: [DocumentID: Database.Document], orphaned: [DocumentID]) {
        guard !ids.isEmpty else { return ([:], []) }
        let flat = root.appendingPathComponent(DocumentFiles.flatFolder, isDirectory: true)
        guard FileManager.default.fileExists(atPath: flat.path(percentEncoded: false)) else { return ([:], ids) }

        logger.info("Registry Init", "\(ids.count) document(s) not in their shards; copying them from \(DocumentFiles.flatFolder)/")
        let results = LockedValue((adopted: [DocumentID: Database.Document](), orphaned: [DocumentID](), failed: 0))
        let lanes = 8
        DispatchQueue.concurrentPerform(iterations: lanes) { lane in
            for index in stride(from: lane, to: ids.count, by: lanes) {
                let id = ids[index]
                switch DocumentFiles.adopt(DocumentFiles.documentKey(id), root: root, logger: logger.base) {
                case .copied:
                    // Its parts file travels with it; a parts file that is not there is copied
                    // when a search first needs it (partitionDatas).
                    _ = DocumentFiles.adopt(DocumentFiles.partsKey(id), root: root, logger: logger.base)
                    let document: Database.Document? = documentStore(for: id).restore()
                    results.withLock { result in
                        if let document { result.adopted[id] = document } else { result.failed += 1 }
                        let done = result.adopted.count + result.orphaned.count + result.failed
                        if done % 5_000 == 0 { logger.info("Registry Init", "\(done) of \(ids.count) copied or checked") }
                    }
                case .absent:
                    results.withLock { $0.orphaned.append(id) }
                case .failed:
                    results.withLock { $0.failed += 1 }
                }
            }
        }
        let result = results.withLock { $0 }
        logger.info("Registry Init", "\(result.adopted.count) document(s) copied into shards, \(result.orphaned.count) found nowhere, \(result.failed) left for the next start")
        return (result.adopted, result.orphaned)
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
    /// `shared` adds the shared lanes' (Link) for a listing; a change of group never asks.
    nonisolated func groups(for ownerId: OwnerID, lane: LaneID = .unscoped, shared: Bool = false) -> [Database.Group] {
        guard let registry else { return [] }
        let owner = ThreadRegistry.Owner(id: ownerId)
        return (registry.ownersGroups[owner] ?? []).compactMap { entry in
            let readable = shared ? registry.isGroupVisible(entry.id, from: lane) : registry.isGroupReadable(entry.id, from: lane)
            guard entry.ownerId == owner.id, readable else { return nil }
            return buildGroup(entry: entry, registry: registry)
        }
    }

    nonisolated func availableGroups(lane: LaneID = .unscoped) -> [Database.Group] {
        guard let registry else { return [] }
        return registry.availableGroupIds
            .filter { registry.isGroupVisible($0, from: lane) }
            .compactMap { buildGroup(groupId: $0, registry: registry) }
    }

    /// Returns lightweight group entries (documents NOT loaded) for the given owner,
    /// cut to `lane`. Useful for pagination: apply cursor/limit to the entries, then
    /// buildGroup only on the page.
    nonisolated func groupEntries(for ownerId: OwnerID, lane: LaneID = .unscoped) -> [Database.Group] {
        guard let registry else { return [] }
        let owner = ThreadRegistry.Owner(id: ownerId)
        return (registry.ownersGroups[owner] ?? []).filter {
            $0.ownerId == owner.id && registry.isGroupVisible($0.id, from: lane)
        }
    }

    /// Returns lightweight group entries for all available (public) groups in `lane`.
    nonisolated func availableGroupEntries(lane: LaneID = .unscoped) -> [Database.Group] {
        guard let registry else { return [] }
        return registry.availableGroupIds.filter { registry.isGroupVisible($0, from: lane) }.compactMap { id in
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
