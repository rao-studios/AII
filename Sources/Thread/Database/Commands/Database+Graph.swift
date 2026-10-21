//
//  Database+Graph.swift
//  Thread
//
//  Created by Ritesh Pakala on 07/16/26.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation

extension Database {
    struct GraphQuery {
        var entity: String?
        var queryVector: [Float]?
        var kinds: Set<String>?
        var hops: Int = 1
        var limit: Int = 20
        var includeDocuments: Bool = true
    }

    struct GraphQueryResult {
        var entities: [GraphResponseEntity] = []
        var relationships: [GraphResponseRelationship] = []
        var documents: [GraphResponseDocument] = []
        var entityCount: Int = 0
        var relationshipCount: Int = 0
    }

    nonisolated func graphQuery(_ query: GraphQuery, request: DatabaseRequest) -> GraphQueryResult {
        guard let graph = self.graph, !graph.entities.isEmpty else { return GraphQueryResult() }

        let scoreById: [EntityID: Float]
        let reachedEntities: Set<EntityID>
        let reachedEdges: Set<RelationshipID>

        let browsing = (query.entity?.isEmpty ?? true)
            && (query.queryVector?.isEmpty ?? true)
        // Access filter: owner docs + publicly available docs, cut to the caller's lane.
        let ownerKey = ThreadRegistry.Owner(id: request.ownerId)
        let laneDocuments = self.registry?.documents(inLane: request.lane)
        let accessible: Set<DocumentID> = {
            guard let registry = self.registry else { return [] }
            var set = registry.availableDocumentIds.union(Set(registry.ownersDocuments[ownerKey] ?? []))
            if let laneDocuments { set.formIntersection(laneDocuments) }
            return set
        }()

        if browsing {
            let filtered = graph.entities.values.filter { entity in
                // Browsing shows the lane's graph: entities no document of the lane mentions stay out.
                if let laneDocuments, entity.documentIds.isDisjoint(with: laneDocuments) { return false }
                guard let kinds = query.kinds, !kinds.isEmpty else { return true }
                return kinds.contains(entity.kind)
            }
            let top = filtered
                .sorted { ($0.mentionCount, $0.name) > ($1.mentionCount, $1.name) }
                .prefix(max(query.limit, 1))
            reachedEntities = Set(top.map(\.id))
            reachedEdges = Set(graph.relationships.values.filter {
                reachedEntities.contains($0.subjectId) && reachedEntities.contains($0.objectId)
            }.map(\.id))
            scoreById = [:]
        } else {
            let matches = graph.matchEntities(nameQuery: query.entity, kinds: query.kinds, limit: query.limit)
            scoreById = Dictionary(matches.map { ($0.entity.id, $0.score) }, uniquingKeysWith: max)
            let matchedRelationships = query.queryVector.map {
                graph.matchRelationships(embedding: $0, seededBy: Set(matches.map { $0.entity.id }), limit: query.limit)
            } ?? []
            let relationshipIds = Set(matchedRelationships.map { $0.relationship.id })
            let seeds = Set(matches.map { $0.entity.id }).union(graph.endpointIds(for: relationshipIds))

            let hops = min(max(query.hops, 0), 3)
            let traversed = graph.neighborhood(of: seeds, hops: hops)
            reachedEntities = traversed.entities
            reachedEdges = traversed.relationships.union(relationshipIds)
        }

        let responseEntities: [GraphResponseEntity] = reachedEntities.compactMap { id in
            guard let e = graph.entities[id] else { return nil }
            return GraphResponseEntity(
                id: e.id, name: e.name, kind: e.kind,
                score: scoreById[id] ?? 0,
                mentionCount: e.mentionCount,
                documentIds: Array(e.documentIds.intersection(accessible)).sorted()
            )
        }.sorted { $0.score > $1.score }

        let responseRelationships: [GraphResponseRelationship] = reachedEdges.compactMap { rid in
            guard let rel = graph.relationships[rid] else { return nil }
            return GraphResponseRelationship(
                id: rel.id, subjectId: rel.subjectId, predicate: rel.predicate, objectId: rel.objectId,
                weight: rel.weight,
                documentIds: Array(rel.documentIds.intersection(accessible)).sorted()
            )
        }

        var documents: [GraphResponseDocument] = []
        if query.includeDocuments {
            let docIds = graph.documents(linkedToEntities: reachedEntities).intersection(accessible)
            documents = docIds.sorted().map { id in
                let doc = self.document(for: id)
                return GraphResponseDocument(id: id, name: doc?.name, ownerId: doc?.ownerId)
            }
        }

        // Node-wide counts for a Thread with no lanes; the lane's own otherwise.
        let counts = laneDocuments == nil
            ? (entities: graph.entities.count, relationships: graph.relationships.count)
            : {
                let own = stats(lane: request.lane)
                return (entities: own.entities, relationships: own.relationships)
            }()
        return GraphQueryResult(
            entities: responseEntities,
            relationships: responseRelationships,
            documents: documents,
            entityCount: counts.entities,
            relationshipCount: counts.relationships
        )
    }
}
