//
//  ThreadQueryServiceImpl.swift
//  Thread
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//

import Seam
import Foundation
import GRPCCore
import GRPCProtobuf
import Logging

/// The Query service. Every RPC is cut to the caller's lane: on the direct port the
/// lane comes from the secret in the metadata (`ServiceProtocol` gives us the request
/// head), on the session stream from the lane Sewn stamped. The message's own `lane`
/// field is ignored on a direct call — a client never names its lane.
final class ThreadQueryServiceImpl: Thread_V1_ThreadQuery.ServiceProtocol, Sendable {
    let database: Database
    let embeddingProvider: any EmbeddingProviding
    let graphExtractor: any GraphExtracting
    let resolver: LaneResolver

    /// Search-scoped embedding cache (process-wide: the session dispatcher
    /// and direct gRPC each hold an impl, both should share hits). The model
    /// is fixed per process, so text → vector is stable.
    static let queryEmbeddingCache = QueryEmbeddingCache()

    init(database: Database, embeddingProvider: any EmbeddingProviding,
         graphExtractor: any GraphExtracting, resolver: LaneResolver = .unscoped) {
        self.database = database
        self.embeddingProvider = embeddingProvider
        self.graphExtractor = graphExtractor
        self.resolver = resolver
    }

    // MARK: - Direct port (ServiceProtocol)

    func search(
        request: GRPCCore.ServerRequest<Thread_V1_ThreadSearchRequest>,
        context: GRPCCore.ServerContext
    ) async throws -> GRPCCore.ServerResponse<Thread_V1_ThreadSearchResponse> {
        ServerResponse(message: try await search(request.message, caller: .metadata(request.metadata)))
    }

    func index(
        request: GRPCCore.ServerRequest<Thread_V1_ThreadIndexRequest>,
        context: GRPCCore.ServerContext
    ) async throws -> GRPCCore.ServerResponse<Thread_V1_ThreadIndexResponse> {
        ServerResponse(message: try await index(request.message, caller: .metadata(request.metadata)))
    }

    func remove(
        request: GRPCCore.ServerRequest<Thread_V1_ThreadRemoveRequest>,
        context: GRPCCore.ServerContext
    ) async throws -> GRPCCore.ServerResponse<Thread_V1_ThreadRemoveResponse> {
        ServerResponse(message: try await remove(request.message, caller: .metadata(request.metadata)))
    }

    // MARK: - Search

    func search(
        _ request: Thread_V1_ThreadSearchRequest,
        caller: LaneCaller
    ) async throws -> Thread_V1_ThreadSearchResponse {
        let scope = try resolver.scope(for: caller)
        // Another model's index: nothing in it is comparable with this model's query.
        if await database.vectorRefusal() != nil {
            return Thread_V1_ThreadSearchResponse()
        }
        // The scan is ~0.2ms; the real cost of a search RPC is the query
        // embedding round-trip(s) — timed here because the PartitionTable
        // timer starts after embedding and is structurally blind to it.
        let rpcStart = Date()
        let groups: [Database.Group]? = request.groupIds.isEmpty ? nil :
            request.groupIds.map { Database.Group(id: $0, label: "", ownerId: request.ownerID, documents: []) }

        let databaseReq = DatabaseRequest(
            ownerId: request.ownerID,
            groups: groups,
            entities: request.entities.isEmpty ? nil : Array(request.entities),
            aggregate: request.aggregate,
            scope: request.scope == "global" ? .global : .personal,
            mediaType: request.mediaType.isEmpty ? nil : MediaType(wire: request.mediaType),
            topK: request.topK > 0 ? Int(request.topK) : nil,
            lane: scope.filter ?? .unscoped
        )

        var embedMs = 0
        var cacheHits = 0
        var queryFloats: [Float] = request.queryEmbedding.isEmpty ? [] : Array(request.queryEmbedding)
        var needsQuery = queryFloats.isEmpty && !request.queryText.isEmpty

        if needsQuery, let cached = Self.queryEmbeddingCache.get(request.queryText) {
            queryFloats = cached
            needsQuery = false
            cacheHits += 1
        }
        if needsQuery {
            let embedStart = Date()
            if let (embeds, _) = try? await embeddingProvider.run(
                [request.queryText], logger: database.baseLogger, role: .query
            ) {
                if let entry = embeds.first(where: { $0.index == 0 }),
                   case let .floats(v) = entry.embedding {
                    queryFloats = v
                    Self.queryEmbeddingCache.cache(request.queryText, vector: v)
                }
            }
            embedMs = Int(Date().timeIntervalSince(embedStart) * 1000)
        }

        // The user utterance remains the primary relation vector. Bonnie can
        // additionally send a few question-signature predicates (`contains`,
        // `part of`, `supports`, …); embed them separately so a broad phrase
        // such as "can you reword that" does not drown out the structural
        // relationship that identifies the right project or application fact.
        let predicateHint = Array(request.entities)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
            .joined(separator: ", ")
        var predicateFloats: [Float] = []
        // A code search's entities are identifiers, not predicates: no second embedding.
        if !predicateHint.isEmpty, !databaseReq.isCode {
            let embedStart = Date()
            if let (embeds, _) = try? await embeddingProvider.run(
                ["Relationship predicates: \(predicateHint)"],
                logger: database.baseLogger, role: .query
            ), let entry = embeds.first(where: { $0.index == 0 }),
              case let .floats(vector) = entry.embedding {
                predicateFloats = vector
            }
            embedMs += Int(Date().timeIntervalSince(embedStart) * 1000)
        }

        let queryData = [EmbeddingData(
            embedding: .floats(queryFloats),
            index: 0
        )]

        // Table restore is synchronous within startup; gate the first query on it.
        await database.initializationTask.value

        let matchedEntityIds: Set<EntityID>
        let matchedRelationshipIds: Set<RelationshipID>
        let matchedPredicateIds: Set<PredicateID>
        var identifierScores: [EntityID: Float] = [:]
        if databaseReq.isCode {
            identifierScores = database.identifierScores(queryText: request.queryText,
                                                         entities: Array(request.entities))
            matchedEntityIds = Set(identifierScores.keys)
            matchedRelationshipIds = []
            matchedPredicateIds = []
        } else if let graph = database.graph, !graph.entities.isEmpty {
            let entityQuery = ([request.queryText] + request.entities).joined(separator: " ")
            matchedEntityIds = Set(graph.matchEntities(nameQuery: entityQuery).map { $0.entity.id })
            let primary = graph.matchRelationships(embedding: queryFloats, seededBy: matchedEntityIds)
            let hinted = predicateFloats.isEmpty
                ? []
                : graph.matchRelationships(embedding: predicateFloats)
            let relationships = primary + hinted
            matchedRelationshipIds = Set(relationships.map { $0.relationship.id })
            matchedPredicateIds = Set(relationships.map { $0.predicateId })
        } else {
            matchedEntityIds = []
            matchedRelationshipIds = []
            matchedPredicateIds = []
        }

        let result = await withCheckedContinuation { (cont: CheckedContinuation<Database.SearchResult, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { [database, databaseReq, queryData, identifierScores] in
                cont.resume(returning: database.search(
                    queryData,
                    matchedEntityIds: matchedEntityIds,
                    matchedRelationshipIds: matchedRelationshipIds,
                    matchedPredicateIds: matchedPredicateIds,
                    identifierScores: identifierScores,
                    database: databaseReq
                ))
            }
        }

        var response = Thread_V1_ThreadSearchResponse()
        let registry = request.includeMetadata ? database.registry : nil
        response.results = result.partitionWithScores.map { score, partition in
            var r = Thread_V1_ThreadPartitionResult()
            r.threadID = database.nodeId.uuidString
            r.partitionID = partition.id
            r.documentID = partition.documentId
            r.ownerID = partition.ownerId
            r.text = partition.text
            r.score = score
            r.shardIndex = 0
            if request.includeMetadata {
                let header = database.documentHeader(for: partition.documentId, owner: partition.ownerId, registry: registry)
                r.name = header.name ?? ""
                r.groupID = header.groupId ?? ""
                if let metadata = header.metadata { r.metadata = metadata }
                // The partition's own address, when its filer gave one (a region of a picture).
                // A partition read without its data carries an empty file url: not an address.
                if let documentURL = header.documentURL, partition.url != documentURL,
                   partition.url != URL(fileURLWithPath: "") {
                    r.url = partition.url.absoluteString
                }
            }
            return r
        }
        if let trace = result.trace {
            var t = Thread_V1_ThreadGraphTrace()
            t.matchedEntityIds = trace.matchedEntityIds
            t.expansionEdgeIds = trace.expansionEdges
            t.expandedDocumentCount = Int32(trace.expandedDocumentCount)
            t.matchedEntityNames = trace.matchedEntityNames
            t.mediaType = trace.mediaType
            response.trace = t
        }
        let totalMs = Int(Date().timeIntervalSince(rpcStart) * 1000)
        let instrument = databaseReq.isCode
            ? " instrument=code matched=\(matchedEntityIds.count) boosted=\(result.trace?.boostedDocumentCount ?? 0)"
            : ""
        database.logger.info(
            nil,
            "[timing] search rpc=\(totalMs)ms embed=\(embedMs)ms cache_hits=\(cacheHits) other=\(totalMs - embedMs)ms results=\(response.results.count)\(instrument)")
        return response
    }

    // MARK: - Index

    func index(
        _ request: Thread_V1_ThreadIndexRequest,
        caller: LaneCaller
    ) async throws -> Thread_V1_ThreadIndexResponse {
        let lane = try resolver.writeLane(try resolver.scope(for: caller))
        // Another model's index is held as it is, so choosing that model again finds
        // it whole. The caller is told why rather than filing into the wrong space.
        if let refusal = await database.vectorRefusal() {
            throw RPCError(code: .failedPrecondition, message: refusal)
        }
        // A document another app filed stays that app's: the caller is told whose,
        // before anything is embedded. `Database.putBatch` enforces the same rule
        // for whatever slips past (the put runs after this answer).
        if let registry = database.registry, !lane.isUnscoped {
            for item in request.items {
                let existing = registry.lane(of: item.documentID)
                if !existing.isUnscoped, existing != lane {
                    throw RPCError(code: .failedPrecondition,
                                   message: "document \(item.documentID) belongs to \(resolver.appName(for: existing))'s lane")
                }
            }
        }
        let group: Database.Group? = request.groupID.isEmpty ? nil :
            Database.Group(id: request.groupID, label: request.groupLabel, ownerId: request.ownerID, documents: [])

        let resolvedOwner = request.ownerID.isEmpty ? "\(database.nodeId.uuidString)-thread" : request.ownerID
        // A group is its first owner's, in its first lane: naming another's is refused here,
        // where the caller hears it, instead of filing the documents with no group.
        if let group, let registry = database.registry {
            if let holder = registry.groupOwners[group.id], holder != ThreadRegistry.Owner(id: resolvedOwner) {
                throw RPCError(code: .failedPrecondition,
                               message: "group \(group.id) belongs to another owner; file under a group of your own")
            }
            if !lane.isUnscoped, !registry.admits(groupId: group.id, lane: lane) {
                throw RPCError(code: .failedPrecondition,
                               message: "group \(group.id) belongs to \(resolver.appName(for: registry.lane(ofGroup: group.id)))'s lane")
            }
        }
        // A vector the caller supplies must come from the index's own embedder: the size
        // is checked here, since a vector of another size would be filed and never match.
        let expectedDimensions = embeddingProvider.vectorSpace
            .flatMap { $0.split(separator: "@").last }.flatMap { Int($0) }
        let databaseReq = DatabaseRequest(
            ownerId: resolvedOwner,
            group: group,
            scope: request.scope == "global" ? .global : .personal,
            lane: lane
        )
        let entityCap = ExtractionPolicyStore.current.maxEntities

        var putItems: [Database.BatchPutItem] = []
        var fullCIDs: [String] = []

        for item in request.items {
            let texts = Array(item.texts)
            guard !texts.isEmpty else { continue }
            let mediaType = MediaType(wire: item.mediaType)

            // Provisional entities: caller-provided `entities`, else the legacy `tags`
            // alias as concept entities, else what the document's kind calls for
            // (ExtractionRoute): keywords pending the LLM for prose, its identifiers
            // for code, nothing for a picture.
            var resolvedEntities: [Database.GraphPayload.EntityIn] = item.entities.map {
                .init(name: $0.name, kind: $0.kind.isEmpty ? "concept" : $0.kind)
            }
            if resolvedEntities.isEmpty {
                resolvedEntities = item.tags.map { .init(name: $0, kind: "concept") }
            }
            var needsExtraction = false
            if resolvedEntities.isEmpty {
                let route = ExtractionRoute.decide(mediaType: mediaType, hasCallerEntities: false)
                (resolvedEntities, needsExtraction) = route.entities(for: texts, cap: entityCap)
            }
            let relations: [Database.GraphPayload.RelationIn] = item.relationships.map {
                .init(subject: $0.subject, predicate: $0.predicate, object: $0.object)
            }
            let graph = Database.GraphPayload(entities: resolvedEntities, relationships: relations)

            // A caller may describe partitions itself (`partitions`, parallel to
            // `texts`): a supplied embedding is used as-is and kept, a supplied url
            // replaces the document's. Only texts without an embedding are sent to
            // this node's embedder.
            let described = Array(item.partitions)
            guard described.isEmpty || described.count == texts.count else {
                throw RPCError(code: .invalidArgument,
                               message: "document \(item.documentID): \(described.count) partitions for \(texts.count) texts")
            }
            var vectors = [[Float]?](repeating: nil, count: texts.count)
            for (i, partition) in described.enumerated() where !partition.embedding.isEmpty {
                if let expectedDimensions, partition.embedding.count != expectedDimensions {
                    throw RPCError(code: .invalidArgument,
                                   message: "document \(item.documentID): partition \(i) has \(partition.embedding.count) dimensions; this index's embedder makes \(expectedDimensions)")
                }
                vectors[i] = Array(partition.embedding)
            }
            let missing = vectors.indices.filter { vectors[$0] == nil }
            if !missing.isEmpty {
                let embeddings: [EmbeddingData]
                do {
                    embeddings = try await embeddingProvider.run(
                        missing.map { texts[$0] },
                        logger: database.baseLogger,
                        role: .document
                    ).result
                } catch let notReady as EmbedderNotReady {
                    // First run: the model is still downloading. The caller keeps the
                    // document and files it again, rather than timing out on us.
                    throw RPCError(code: .unavailable, message: notReady.description)
                }
                for entry in embeddings where entry.index < missing.count {
                    if case let .floats(v) = entry.embedding { vectors[missing[entry.index]] = v }
                }
            }
            // One PQ codebook covers every partition of a document and slices each
            // vector the same way, so they must agree on a dimensionality it divides.
            let dimensions = Set(vectors.compactMap { $0?.count }.filter { $0 > 0 })
            guard dimensions.count <= 1 else {
                throw RPCError(code: .invalidArgument,
                               message: "document \(item.documentID): partitions disagree on dimensionality \(dimensions.sorted())")
            }
            if let dim = dimensions.first, dim % PartitionQuantizer.defaultNumSubvectors != 0 {
                throw RPCError(code: .invalidArgument,
                               message: "document \(item.documentID): dimensionality \(dim) is not a multiple of \(PartitionQuantizer.defaultNumSubvectors)")
            }
            let partitionEmbeddings = vectors.enumerated()
                .map { EmbeddingData(embedding: .floats($0.element ?? []), index: $0.offset) }
            let overrides: [Database.BatchPutItem.PartitionOverride]? = described.isEmpty ? nil :
                described.map { .init(url: $0.url.isEmpty ? nil : URL(string: $0.url),
                                      keepEmbedding: !$0.embedding.isEmpty) }

            let fullCID = item.documentID
            fullCIDs.append(fullCID)

            var putItem = Database.BatchPutItem(
                id: fullCID,
                data: partitionEmbeddings,
                texts: texts,
                graph: graph,
                needsExtraction: needsExtraction,
                mediaType: mediaType,
                update: nil,
                name: item.name.isEmpty ? nil : item.name,
                metadata: item.metadata.isEmpty ? nil : item.metadata,
                partitions: overrides
            )
            // Numbered now, while the order is the caller's: the put runs after enrichment,
            // which may finish this filing after a later one of the same id.
            putItem.sequence = database.putSequencer.next()
            putItems.append(putItem)
        }

        guard !putItems.isEmpty else {
            var response = Thread_V1_ThreadIndexResponse()
            response.success = true
            response.indexedCount = 0
            return response
        }

        // Respond now; enrichment (LLM extraction + entity embedding) runs detached and
        // enqueues the put — identical shape to the REST ingest path.
        let capturedItems = putItems
        let capturedReq = databaseReq
        Task.detached(priority: .userInitiated) { [database, graphExtractor, embeddingProvider] in
            let enriched = await GraphEnrichment.run(
                items: capturedItems,
                extractor: graphExtractor,
                embedder: embeddingProvider,
                existingGraph: database.graph,
                logger: database.baseLogger
            )
            await database.enqueuePut(enriched, request: capturedReq)
        }

        var response = Thread_V1_ThreadIndexResponse()
        response.success = true
        response.indexedCount = Int32(putItems.count)
        response.fullCids = fullCIDs
        return response
    }

    // MARK: - Remove

    func remove(
        _ request: Thread_V1_ThreadRemoveRequest,
        caller: LaneCaller
    ) async throws -> Thread_V1_ThreadRemoveResponse {
        let lane = try resolver.writeLane(try resolver.scope(for: caller))
        let ownerId = request.ownerID

        if request.documentIds.isEmpty {
            // Everything the owner holds — in this lane. Owners are shared across apps
            // (one account), so an app's wipe never takes another app's documents.
            let databaseReq = DatabaseRequest(ownerId: ownerId, lane: lane)
            let count = await database.removeAll(ownerId: ownerId, request: databaseReq)
            var response = Thread_V1_ThreadRemoveResponse()
            response.success = true
            response.removedCount = Int32(count)
            return response
        } else {
            let items = request.documentIds.map { (documentId: $0, ownerId: ownerId) }
            await database.enqueueRemoveBatch(items, lane: lane)
            var response = Thread_V1_ThreadRemoveResponse()
            response.success = true
            response.removedCount = Int32(items.count)
            return response
        }
    }
}
