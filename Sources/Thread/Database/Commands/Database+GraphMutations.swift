//
//  Database+GraphMutations.swift
//  Thread
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  Command layer for granular graph editing and per-document re-extraction.
//

import AII
import Foundation

extension Database {

    /// Graph admin's provenance rule: an entity or relationship may be edited from a
    /// lane only when every document it comes from is that lane's. Returns the other
    /// lanes it touches (empty when the edit may proceed, or when the caller has no
    /// lane — the stack identity, or a Thread with no lanes). Unknown ids pass: the
    /// mutation itself answers for them.
    nonisolated func foreignLanes(ofEntity id: EntityID, outside lane: LaneID) -> Set<LaneID> {
        guard !lane.isUnscoped, let registry, let entity = graph?.entities[id] else { return [] }
        return registry.foreignLanes(of: entity.documentIds, outside: lane)
    }

    nonisolated func foreignLanes(ofRelationship id: RelationshipID, outside lane: LaneID) -> Set<LaneID> {
        guard !lane.isUnscoped, let registry, let relationship = graph?.relationships[id] else { return [] }
        return registry.foreignLanes(of: relationship.documentIds, outside: lane)
    }

    @discardableResult
    func deleteEntity(id: EntityID) async -> EntityID? {
        await tableMutator.mutateGraph(.deleteEntity(id))
    }

    func deleteRelationship(id: RelationshipID) async {
        await tableMutator.mutateGraph(.deleteRelationship(id))
    }

    @discardableResult
    func renameEntity(id: EntityID, newName: String) async -> EntityID? {
        await tableMutator.mutateGraph(.renameEntity(id, newName: newName))
    }

    @discardableResult
    func mergeEntities(from: EntityID, into target: EntityID) async -> EntityID? {
        await tableMutator.mutateGraph(.mergeEntities(from: from, into: target))
    }

    @discardableResult
    func setEntityKind(id: EntityID, kind: String) async -> EntityID? {
        await tableMutator.mutateGraph(.setEntityKind(id, kind: kind))
    }

    func reExtract(
        documentId: DocumentID,
        extractor: any GraphExtracting,
        embedder: any EmbeddingProviding,
        request: DatabaseRequest
    ) async -> Int? {
        // Another lane's document is not this caller's to re-read.
        guard registry?.isReadable(documentId, from: request.lane) ?? true else { return nil }
        let parts: [PartitionData]? = partitionStore(for: documentId).restore()
        let texts = (parts ?? []).map { $0.data }.filter { !$0.isEmpty }
        guard !texts.isEmpty else { return nil }

        // Re-extraction follows the document's route: prose goes to the LLM, code
        // takes its identifiers, a picture has nothing to read.
        let mediaType = parts?.first?.mediaType ?? .text
        let route = ExtractionRoute.decide(mediaType: mediaType, hasCallerEntities: false)
        let (provisional, needsExtraction) = route.entities(for: texts, cap: ExtractionPolicyStore.current.maxEntities)
        guard needsExtraction || !provisional.isEmpty else { return nil }

        // Synthetic put item: extraction + embedding pipeline reused verbatim.
        let item = Database.BatchPutItem(
            id: documentId,
            data: [],
            texts: texts,
            graph: .init(entities: provisional),
            needsExtraction: needsExtraction,
            mediaType: mediaType
        )
        let enriched = await GraphEnrichment.run(
            items: [item],
            extractor: extractor,
            embedder: embedder,
            existingGraph: graph,
            logger: baseLogger
        )
        guard let result = enriched.first, !result.graph.isEmpty else { return nil }

        await tableMutator.reapplyGraph(
            documentId: documentId,
            payload: result.graph,
            request: request
        )
        return result.graph.entities.count
    }

    /// Code relations, after the put: each code item a filer asked to relate (`relate_code`) is read by the extractor for
    /// the end goals its types serve (CodeRelationEnrichment), its new relationships are embedded as any filing's are
    /// (GraphEnrichment), and its graph is re-applied behind the put in the write queue, so it lands on the document as
    /// filed. A document filed again meanwhile is the newer filing's to relate: re-applying to a document no longer held
    /// does nothing. Filings reach this through CodeRelationQueue, one reading at a time.
    func relateCode(_ items: [Database.BatchPutItem], extractor: (any GraphExtracting)?, embedder: any EmbeddingProviding,
                    request: DatabaseRequest) async {
        guard let extractor else { return }
        for item in items {
            await relate(item, extractor: extractor, embedder: embedder, request: request)
        }
    }

    /// One code item's reading (see relateCode).
    func relate(_ item: Database.BatchPutItem, extractor: any GraphExtracting, embedder: any EmbeddingProviding,
                request: DatabaseRequest) async {
        guard item.mediaType == .code,
              let related = await CodeRelationEnrichment.relate(item, extractor: extractor, existingGraph: graph, logger: baseLogger) else {
            return
        }
        var reading = item
        reading.graph = related
        reading.needsExtraction = false
        let embedded = await GraphEnrichment.run(items: [reading], extractor: nil, embedder: embedder, existingGraph: graph, logger: baseLogger)
        guard let payload = embedded.first?.graph else { return }
        enqueueReapplyGraph(item.id, payload: payload, request: request)
    }
}
