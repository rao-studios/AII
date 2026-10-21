//
//  Database+Put.swift
//  Thread
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//

import AII
import Foundation
import Logging

extension Database {
    struct BatchPutItem {
        let id: String
        let data: [EmbeddingData]
        let texts: [String]
        var graph: Database.GraphPayload
        /// True when the graph payload is only a keyword placeholder and should be replaced
        /// by LLM extraction in the detached enrichment pass.
        var needsExtraction: Bool
        let mediaType: MediaType
        let update: DatabaseUpdate?
        let name: String?
        let metadata: Data?
        /// Per-partition overrides, parallel to `data`/`texts`. Nil keeps every
        /// partition exactly as before: the document's url, no kept embedding.
        let partitions: [PartitionOverride]?
        /// The filing's number from `Database.putSequencer`, taken when Index answered;
        /// 0 for a path that doesn't number its filings, which is always applied.
        var sequence: UInt64 = 0

        /// What a caller may say about one partition it describes itself.
        struct PartitionOverride: Sendable {
            /// The partition's own address instead of the document's.
            var url: URL?
            /// Keep the full embedding in `-parts` — set when the caller supplied it.
            var keepEmbedding: Bool

            init(url: URL? = nil, keepEmbedding: Bool = false) {
                self.url = url
                self.keepEmbedding = keepEmbedding
            }
        }

        init(id: String,
             data: [EmbeddingData],
             texts: [String],
             graph: Database.GraphPayload = .init(),
             needsExtraction: Bool = false,
             mediaType: MediaType = .text,
             update: DatabaseUpdate? = nil,
             name: String? = nil,
             metadata: Data? = nil,
             partitions: [PartitionOverride]? = nil) {
            self.id = id
            self.data = data
            self.texts = texts
            self.graph = graph
            self.needsExtraction = needsExtraction
            self.mediaType = mediaType
            self.update = update
            self.name = name
            self.metadata = metadata
            self.partitions = partitions
        }
    }
}

/// Numbers filings process-wide, in the order Index answers them.
final class PutSequencer: Sendable {
    private let last = LockedValue<UInt64>(0)

    func next() -> UInt64 { last.withLock { $0 &+= 1; return $0 } }
}

extension Database {
    func put(_ key: String, document: Database.Document) {
        let storage = FilePersistence(key: key, kind: .basic, logger: logger.base)
        storage.save(state: document)
    }

    @discardableResult
    func put(id: String,
             data: [EmbeddingData],
             texts: [String],
             graph: Database.GraphPayload = .init(),
             mediaType: MediaType = .text,
             update: DatabaseUpdate? = nil,
             name: String? = nil,
             metadata: Data? = nil,
             request: DatabaseRequest) async -> Database.Document {
        let storage = documentStore(for: id)
        var partitions: [Database.Partition] = []

        for (i, d) in data.enumerated() {
            guard case let .floats(array) = d.embedding, !array.isEmpty else { continue }
            partitions.append(Database.Partition(
                id: computeNumericHash(from: array, documentId: id, index: i),
                documentId: id,
                url: storage.url,
                embedding: array,
                mediaType: mediaType,
                text: texts[i],
                ownerId: request.ownerId
            ))
        }

        // The authoritative lane guard: a document another lane filed is never
        // re-filed, whatever a caller's pre-check said.
        if let registry, !registry.admits(documentId: id, lane: request.lane) {
            logger.warning("Put: refused \(id) — it belongs to lane \(registry.lane(of: id)), not \(request.lane)",
                           service: .embedding, request: request)
            return Database.Document(id: id, url: storage.url, ownerId: request.ownerId, name: name, laneId: registry.lane(of: id))
        }

        let document = Database.Document(id: id, url: storage.url, ownerId: request.ownerId, name: name, laneId: request.lane)
        storage.save(state: document)
        documentCache.cache(document)

        await register(document, group: request.group, update: update, ownerId: request.ownerId, lane: request.lane)
        logger.info("Put", "Registered document (docId: \(id), partitions: \(partitions.count))", service: .embedding, request: request, flow: .embed(documentId: id))
        await index(id: id, partitions: partitions, graph: graph, metadata: metadata, request: request)
        logger.info("Put", "Indexed document (docId: \(id)) → partition table + graph", service: .embedding, request: request, flow: .embed(documentId: id))

        return document
    }

    /// Returns `false` when the document is another lane's (nothing is linked).
    @discardableResult
    func linkOwner(documentId: String, request: DatabaseRequest) async -> Bool {
        let linked = await registryMutator.linkOwner(documentId: documentId, group: request.group,
                                                     ownerId: request.ownerId, lane: request.lane)
        if linked {
            logger.info("Link Owner", "Linked owner \(request.ownerId) to existing document (docId: \(documentId))", service: .embedding, request: request, flow: .embed(documentId: documentId))
        } else {
            logger.warning("Link Owner: refused \(documentId) — another lane's document", service: .embedding, request: request)
        }
        return linked
    }

    /// Returns the ids refused for being another lane's.
    @discardableResult
    func linkOwnerBatch(documentIds: [String], request: DatabaseRequest) async -> [DocumentID] {
        guard !documentIds.isEmpty else { return [] }
        let items = documentIds.map { (documentId: $0, group: request.group, ownerId: request.ownerId) }
        let refused = await registryMutator.linkOwnerBatch(items: items, lane: request.lane)
        logger.info("Link Owner Batch", "Linked owner \(request.ownerId) to \(documentIds.count - refused.count) existing document(s)\(refused.isEmpty ? "" : ", refused \(refused.count) in another lane")", service: .embedding, request: request)
        return refused
    }

    func putBatch(_ items: [BatchPutItem], request: DatabaseRequest) async {
        // The authoritative lane guard. `index` answers before this runs, so its
        // pre-check is advice; a document another lane filed is dropped here, logged,
        // whatever the caller was told.
        let admittedItems: [BatchPutItem] = {
            guard let registry, !request.lane.isUnscoped else { return items }
            return items.filter { item in
                let admitted = registry.admits(documentId: item.id, lane: request.lane)
                if !admitted {
                    logger.warning("Put Batch: dropped \(item.id) — it belongs to lane \(registry.lane(of: item.id)), not \(request.lane)",
                                   service: .embedding, request: request)
                }
                return admitted
            }
        }()
        // A group is its first owner's, in its first lane. `index` refuses a caller that
        // names another's; here, after the answer, such a batch is dropped and logged
        // rather than filed with no group, where nothing that lists groups would find it.
        if let registry, let group = request.group {
            let holder = registry.groupOwners[group.id]
            let ownersGroup = holder == nil || holder == ThreadRegistry.Owner(id: request.ownerId)
            guard ownersGroup, request.lane.isUnscoped || registry.admits(groupId: group.id, lane: request.lane) else {
                logger.warning("Put Batch: dropped \(admittedItems.count) doc(s) — group \(group.id) belongs to another owner or lane",
                               service: .embedding, request: request)
                return
            }
        }
        // Filings of one id apply in the order Index answered them: enrichment runs
        // detached, so an older filing can reach this queue after a newer one. A numbered
        // item older than the last applied for its id, or than a later item in this
        // batch, is dropped.
        let items: [BatchPutItem] = {
            var newest: [String: UInt64] = [:]
            for item in admittedItems where item.sequence > 0 {
                newest[item.id] = max(newest[item.id] ?? 0, item.sequence)
            }
            return admittedItems.filter { item in
                guard item.sequence > 0 else { return true }
                let stale = item.sequence < (newest[item.id] ?? 0)
                    || item.sequence < (appliedPutSequence[item.id] ?? 0)
                if stale {
                    logger.info("Put Batch", "Skipped an older filing of \(item.id)", service: .embedding, request: request)
                }
                return !stale
            }
        }()
        for item in items where item.sequence > 0 {
            appliedPutSequence[item.id] = item.sequence
        }
        guard !items.isEmpty else { return }

        logger.info(
            "Put Batch",
            "Starting batch index (\(items.count) doc(s), \(items.reduce(0) { $0 + $1.data.count }) partition(s))",
            service: .embedding, request: request
        )

        struct Prepared {
            let document: Database.Document
            let partitions: [Database.Partition]
            /// Parallel to `partitions`: keep that partition's embedding in `-parts`.
            let keepEmbeddings: [Bool]
            let update: DatabaseUpdate?
        }

        var prepared: [Prepared] = []
        prepared.reserveCapacity(items.count)

        for item in items {
            let storage = documentStore(for: item.id)
            let built: [(Database.Partition, Bool)] = item.data.enumerated().compactMap { i, d in
                guard case let .floats(array) = d.embedding, !array.isEmpty else { return nil }
                let override = item.partitions.flatMap { i < $0.count ? $0[i] : nil }
                return (Database.Partition(
                    id: computeNumericHash(from: array, documentId: item.id, index: i),
                    documentId: item.id,
                    url: override?.url ?? storage.url,
                    embedding: array,
                    mediaType: item.mediaType,
                    text: item.texts[i],
                    ownerId: request.ownerId
                ), override?.keepEmbedding ?? false)
            }
            let document = Database.Document(id: item.id, url: storage.url, ownerId: request.ownerId, name: item.name,
                                             laneId: request.lane)
            prepared.append(Prepared(document: document, partitions: built.map(\.0),
                                     keepEmbeddings: built.map(\.1), update: item.update))
        }

        // Persist document + partition-content files in a bounded parallel task
        // group, off this actor, BEFORE indexing — the `documents/{id}-parts`
        // file must be durable before the document becomes searchable (the
        // search path resolves partition text from it), and TableMutator is told
        // below (persistPartitionData: false) not to repeat these writes.
        let loggerBase = logger.base
        await withTaskGroup(of: Void.self) { group in
            let writeWidth = 8
            var inFlight = 0
            for item in prepared {
                if inFlight >= writeWidth {
                    await group.next()
                    inFlight -= 1
                }
                let document = item.document
                let partitionData = zip(item.partitions, item.keepEmbeddings).map {
                    PartitionData(from: $0, keepEmbedding: $1)
                }
                group.addTask {
                    FilePersistence(key: "documents/\(document.id)", kind: .basic, logger: loggerBase)
                        .save(state: document)
                    FilePersistence(key: "documents/\(document.id)-parts", kind: .basic, logger: loggerBase)
                        .save(state: partitionData)
                }
                inFlight += 1
            }
        }

        documentCache.cacheBatch(prepared.map { $0.document })

        await registryMutator.registerBatch(
            items: prepared.map { ($0.document, request.group, request.ownerId) },
            lane: request.lane
        )

        var removedIds = Set<String>()
        for item in prepared {
            if let update = item.update,
               update.operation == .remove,
               removedIds.insert(update.documentId).inserted {
                await remove(documentId: update.documentId, group: request.group, ownerId: request.ownerId,
                             lane: request.lane)
            }
        }

        let indexItems = prepared
        let batchItems: [(id: DocumentID, partitions: [Database.Partition], graph: Database.GraphPayload, metadata: Data?, request: DatabaseRequest)] = zip(indexItems, items).map { prepared, item in
            (prepared.document.id, prepared.partitions, item.graph, item.metadata, request)
        }
        // Parts files were pre-written above — skip the per-document synchronous
        // plist writes on the TableMutator actor.
        await tableMutator.putBatch(items: batchItems, persistPartitionData: false)

        for item in prepared {
            logger.info(
                "Put Batch",
                "Indexed document (docId: \(item.document.id), partitions: \(item.partitions.count)) → partition table + graph",
                service: .embedding,
                request: request,
                flow: .embed(documentId: item.document.id)
            )
        }
    }
}
