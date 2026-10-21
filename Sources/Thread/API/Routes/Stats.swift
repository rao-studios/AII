//
//  Stats.swift
//  Thread
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: `GET /v1/stats` — what the caller's lane of the index holds: documents,
//        groups, owners, the entities and relationships its documents mention,
//        its most-mentioned entities. The stack identity gets the whole node and
//        every lane's counts (`lanes`); a Thread with no lanes answers the node.
//  WHY:  The one number every app shows beside "Ambient Intelligence Index", over
//        HTTP so the AII client needs no gRPC. Counts come from LaneStatsCache:
//        recomputed when the stores change, never per poll.
//

import AII
import Foundation
import Hummingbird

struct StatsResponse: ResponseCodable {
    let lane: LaneID
    let documents: Int
    let groups: Int
    let owners: Int
    let entities: Int
    let relationships: Int
    let topEntities: [LaneStats.TopEntity]
    /// Every lane's counts — the stack identity only.
    let lanes: [LaneStats]?

    enum CodingKeys: String, CodingKey {
        case lane, documents, groups, owners, entities, relationships, lanes
        case topEntities = "top_entities"
    }

    init(_ stats: LaneStats, lanes: [LaneStats]?) {
        self.lane = stats.lane
        self.documents = stats.documents
        self.groups = stats.groups
        self.owners = stats.owners
        self.entities = stats.entities
        self.relationships = stats.relationships
        self.topEntities = stats.topEntities
        self.lanes = lanes
    }
}

func registerStatsRoute(_ app: some RouterMethods<ThreadRequestContext>, _ database: Database,
                        resolver: LaneResolver = .unscoped) {
    app.get("/v1/stats") { _, context async throws -> StatsResponse in
        let scope = try resolver.scope(identity: context.callerIdentity)
        let own = database.stats(lane: scope.filter ?? .unscoped)
        var lanes: [LaneStats]?
        if case .all = scope {
            lanes = database.statsByLane().values.sorted { $0.lane.rawValue < $1.lane.rawValue }
        }
        return StatsResponse(own, lanes: lanes)
    }
}
