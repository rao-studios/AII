//
//  ThreadGraphServiceImpl.swift
//  Thread
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//

import AII
import Seam
import Foundation
import GRPCCore
import GRPCProtobuf
import Logging

/// The Graph service, cut to the caller's lane (see ThreadQueryServiceImpl).
final class ThreadGraphServiceImpl: Thread_V1_ThreadGraph.ServiceProtocol, Sendable {
    let database: Database
    let embeddingProvider: any EmbeddingProviding
    let resolver: LaneResolver

    init(database: Database, embeddingProvider: any EmbeddingProviding, resolver: LaneResolver = .unscoped) {
        self.database = database
        self.embeddingProvider = embeddingProvider
        self.resolver = resolver
    }

    func query(
        request: GRPCCore.ServerRequest<Thread_V1_ThreadGraphQueryRequest>,
        context: GRPCCore.ServerContext
    ) async throws -> GRPCCore.ServerResponse<Thread_V1_ThreadGraphQueryResponse> {
        ServerResponse(message: try await query(request.message, caller: .metadata(request.metadata)))
    }

    func query(
        _ request: Thread_V1_ThreadGraphQueryRequest,
        caller: LaneCaller
    ) async throws -> Thread_V1_ThreadGraphQueryResponse {
        let scope = try resolver.scope(for: caller)
        let databaseReq = DatabaseRequest(ownerId: request.ownerID, lane: scope.filter ?? .unscoped)

        // Thread embeds free-text graph queries server-side for relationship matching.
        var queryVector: [Float]?
        if !request.query.isEmpty {
            let (embeds, _) = try await embeddingProvider.run(
                [request.query], logger: database.baseLogger, role: .query
            )
            if case .floats(let v) = embeds.first?.embedding { queryVector = v }
        }

        await database.initializationTask.value

        let result = database.graphQuery(
            Database.GraphQuery(
                entity: request.entity.isEmpty ? nil : request.entity,
                queryVector: queryVector,
                kinds: request.kinds.isEmpty ? nil : Set(request.kinds.map { GraphStore.normalizeKind($0) }),
                hops: request.hops == 0 ? 1 : Int(request.hops),
                limit: request.limit == 0 ? 20 : Int(request.limit),
                includeDocuments: request.includeDocuments
            ),
            request: databaseReq
        )

        var response = Thread_V1_ThreadGraphQueryResponse()
        response.entities = result.entities.map { e in
            var out = Thread_V1_ThreadGraphEntity()
            out.id = e.id
            out.name = e.name
            out.kind = e.kind
            out.score = e.score
            out.mentionCount = Int32(e.mentionCount)
            out.documentIds = e.documentIds
            return out
        }
        response.relationships = result.relationships.map { r in
            var out = Thread_V1_ThreadGraphRelationship()
            out.id = r.id
            out.subjectID = r.subjectId
            out.predicate = r.predicate
            out.objectID = r.objectId
            out.weight = Int32(r.weight)
            out.documentIds = r.documentIds
            return out
        }
        response.documents = result.documents.map { d in
            var out = Thread_V1_ThreadGraphDocument()
            out.id = d.id
            out.name = d.name ?? ""
            out.ownerID = d.ownerId ?? ""
            return out
        }
        var stats = Thread_V1_ThreadGraphStats()
        stats.entityCount = Int64(result.entityCount)
        stats.relationshipCount = Int64(result.relationshipCount)
        // Every lane's counts, for the stack identity only.
        if case .all = scope {
            stats.lanes = database.statsByLane().values
                .sorted { $0.lane.rawValue < $1.lane.rawValue }
                .map(Self.laneStats)
        }
        response.stats = stats
        return response
    }

    static func laneStats(_ stats: LaneStats) -> Thread_V1_ThreadLaneStats {
        var out = Thread_V1_ThreadLaneStats()
        out.lane = stats.lane.rawValue
        out.documents = Int64(stats.documents)
        out.groups = Int64(stats.groups)
        out.owners = Int64(stats.owners)
        out.entities = Int64(stats.entities)
        out.relationships = Int64(stats.relationships)
        return out
    }
}
