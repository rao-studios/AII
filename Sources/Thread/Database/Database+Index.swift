//
//  Database+Index.swift
//  Thread
//
//  Created by Ritesh Pakala on 11/15/25.
//  Copyright © 2026 Rao Studios LLC.
//

import AII
import Foundation

extension Database {
    /// A helper function to begin the index process after Database+Put.
    /// - Parameters:
    ///   - id: The DocumentID.
    ///   - partitions: The partitions related to the document.
    ///   - graph: The extracted entity/relationship payload for this document.
    ///   - request: The DatabaseRequest with owner information.
    func index(
        id: DocumentID,
        partitions: [Database.Partition],
        graph: Database.GraphPayload = .init(),
        metadata: Data? = nil,
        request: DatabaseRequest
    ) async {
        await tableMutator.put(id: id, partitions: partitions, graph: graph,
                               metadata: metadata, request: request)
    }

    /// Deletes or unlinks every document owned by a user.
    ///
    /// Documents where this owner was the last are fully purged (file + table + graph).
    /// Documents still held by other owners are only unlinked in the registry.
    @discardableResult
    func _removeAll(ownerId: String, request: DatabaseRequest) async -> Int {
        let (fullyRemoved, allOwned) = await registryMutator.removeAll(ownerId: ownerId, lane: request.lane)

        for documentId in fullyRemoved { documentCache.evict(documentId) }
        let idsToDelete = fullyRemoved
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            for documentId in idsToDelete {
                self.documentStore(for: documentId).purge()
                self.partitionStore(for: documentId).purge()
            }
        }

        await tableMutator.removeAll(documentIds: fullyRemoved, request: request)

        return allOwned.count
    }

    /// Unlinks a batch of (documentId, ownerId) pairs.
    /// Fully removes documents where the given owner was the last.
    func _removeBatch(items: [(documentId: String, ownerId: String)], lane: LaneID = .unscoped) async {
        guard !items.isEmpty else { return }

        let fullyRemovedIds = await registryMutator.removeBatch(items: items, lane: lane)
        await purge(fullyRemovedIds, lane: lane)
    }

    /// Deletes groups for their owner: the registry unlinks what was filed in them and drops
    /// the groups; what no owner holds any more is purged, as `_removeBatch` purges it.
    func _removeGroups(_ groupIds: [GroupID], ownerId: String, lane: LaneID) async -> Database.GroupRemoval {
        let removal = await registryMutator.removeGroups(groupIds, ownerId: ownerId, lane: lane)
        await purge(removal.fullyRemoved, lane: lane)
        return removal
    }

    /// Documents no owner holds any more leave everything else: the cache now, their
    /// `documents/` and `-parts` files in the background, their table rows and graph links.
    private func purge(_ fullyRemovedIds: [DocumentID], lane: LaneID) async {
        for documentId in fullyRemovedIds { documentCache.evict(documentId) }
        let idsToDelete = fullyRemovedIds
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            for documentId in idsToDelete {
                self.documentStore(for: documentId).purge()
                self.partitionStore(for: documentId).purge()
            }
        }

        let dummyRequest = DatabaseRequest(ownerId: "", group: nil, aggregate: nil, scope: nil, requestID: nil, lane: lane)
        await tableMutator.removeAll(documentIds: fullyRemovedIds, request: dummyRequest)
    }

    /// Unlinks an owner from a document. Only purges the physical file, table entry, and
    /// graph provenance when this owner was the last.
    func remove(documentId: String,
                group: Database.Group? = nil,
                ownerId: String,
                lane: LaneID = .unscoped) async {
        let (authorized, fullyRemoved) = await registryMutator.remove(documentId: documentId, group: group,
                                                                      ownerId: ownerId, lane: lane)
        guard authorized else {
            logger.warning(
                "Owner \(ownerId) does not own document \(documentId) — removal rejected",
                service: .database
            )
            return
        }

        logger.info("Remove Document", "\(fullyRemoved ? "Fully removing" : "Unlinking") document: \(documentId)", service: .database)

        if fullyRemoved {
            documentCache.evict(documentId)
            await tableMutator.remove(id: documentId)
            documentStore(for: documentId).purge()
            partitionStore(for: documentId).purge()
        }
    }
}

extension Database {
    /// Restores the partition table and its companion graph store, reconciles them with the
    /// registry, and seeds the mutator. Durability is debounced full-file saves — there is no
    /// WAL — so this startup sweep closes the small crash window where a document was
    /// registered but its table index had not yet been flushed.
    func initializeTable() {
        let tableStorage = FilePersistence(key: "table-\(nodeId)", kind: .basic, logger: logger.base)
        var table: PartitionTable = tableStorage.restore() ?? .init()

        let graphStorage = FilePersistence(key: "graph-\(nodeId)", kind: .basic, logger: logger.base)
        var graph: GraphStore = graphStorage.restore() ?? .init()

        // ── Sweep 1: table documents absent from the registry → remove from table + graph.
        if let registry = registryMutator.snapshot {
            let validIds = Set(registry.documentOwners.keys)
            let orphanedTableIds = table.keys.subtracting(validIds)
            if !orphanedTableIds.isEmpty {
                for id in orphanedTableIds {
                    let entityIds = table.index(for: id)?.entityIds ?? []
                    table.remove(id: id)
                    graph.detach(documentId: id, entityIds: entityIds)
                }
                tableStorage.save(state: table)
                graphStorage.save(state: graph)
                logger.info(
                    "Table Init",
                    "⚠️ Removed \(orphanedTableIds.count) orphaned document(s) from partition table",
                    service: .database
                )
            }
        }

        // ── Sweep 2: registry documents with no table index → the server crashed inside the
        // 1s debounce window after registering but before the table flushed. Drop them from
        // the registry so re-ingest is not skipped by the doesDocumentExist dedup check.
        if var registry = registryMutator.snapshot {
            let missingIndexIds = registry.documentOwners.keys.filter { table.index(for: $0) == nil }
            if !missingIndexIds.isEmpty {
                for id in missingIndexIds {
                    registry.removeOrphaned(documentId: id)
                    documentCache.evict(id)
                    // Deliberately no file purge: `documents/` is shared and
                    // content-addressed across co-located nodes, so deleting
                    // here can destroy another node's document/parts files.
                    // Dedup gates on `table.keys`, and re-ingest rewrites the
                    // files — an orphaned file is harmless, deletion is not.
                }
                registryStore.save(state: registry)
                registryMutator.seed(registry)
                logger.warning(
                    "⚠️ [Table Init] Dropped \(missingIndexIds.count) registry document(s) missing a table index — re-index required",
                    service: .database
                )
            }
        }

        tableMutator.seed(table)
        tableMutator.seedGraph(graph)
        logger.info(
            "Table Restored",
            "⚜️ Restore Table [table-\(nodeId)] — \(table.keys.count) document(s), \(graph.entities.count) entity(ies)",
            service: .database
        )
    }

    nonisolated var tableStore: FilePersistence {
        FilePersistence(key: "table-\(nodeId)", kind: .basic, logger: logger.base)
    }

    nonisolated var table: PartitionTable? { tableMutator.snapshot }
    nonisolated var graph: GraphStore? { tableMutator.graphSnapshot }
}
