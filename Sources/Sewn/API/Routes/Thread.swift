//
//  Thread.swift
//  Sewn
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//

import Seam
import Foundation
import Hummingbird

struct ThreadNodeStats: Codable {
    let documentCount: Int
    let groupCount: Int
    let ownerCount: Int
    let availableDocumentCount: Int
    /// Every lane's counts — present when the node answered with them.
    let lanes: [LaneStatsInfo]?

    enum CodingKeys: String, CodingKey {
        case documentCount          = "document_count"
        case groupCount             = "group_count"
        case ownerCount             = "owner_count"
        case availableDocumentCount = "available_document_count"
        case lanes
    }

    init(documentCount: Int, groupCount: Int, ownerCount: Int, availableDocumentCount: Int,
         lanes: [LaneStatsInfo]? = nil) {
        self.documentCount = documentCount
        self.groupCount = groupCount
        self.ownerCount = ownerCount
        self.availableDocumentCount = availableDocumentCount
        self.lanes = lanes
    }

    init(_ s: Thread_V1_ThreadStatsResponse) {
        self.init(
            documentCount: Int(s.documentCount),
            groupCount: Int(s.groupCount),
            ownerCount: Int(s.ownerCount),
            availableDocumentCount: Int(s.availableDocumentCount),
            lanes: s.lanes.isEmpty ? nil : s.lanes.map {
                LaneStatsInfo(lane: $0.lane, documents: Int($0.documents), groups: Int($0.groups),
                              owners: Int($0.owners), entities: Int($0.entities), relationships: Int($0.relationships))
            })
    }
}

struct ThreadNodesResponse: Codable {
    let mothershipId: String
    let totalDocumentCount: Int
    let totalGroupCount: Int
    let nodes: [ThreadNodeEntry]
    let enabled: Bool

    enum CodingKeys: String, CodingKey {
        case mothershipId      = "mothership_id"
        case totalDocumentCount = "total_document_count"
        case totalGroupCount    = "total_group_count"
        case nodes
        case enabled
    }
}

struct ThreadNodeEntry: Codable {
    let threadId: String
    let host: String
    let grpcPort: Int
    let httpPort: Int
    let lastSeen: Date
    let isActive: Bool
    let acceptingStorage: Bool
    let stats: ThreadNodeStats?
    /// The app the node registered for on a shared stack; left out when nil.
    let app: String?

    enum CodingKeys: String, CodingKey {
        case threadId         = "thread_id"
        case host
        case grpcPort        = "grpc_port"
        case httpPort        = "http_port"
        case lastSeen        = "last_seen"
        case isActive        = "is_active"
        case acceptingStorage = "accepting_storage"
        case stats
        case app
    }
}

/// `GET /v1/threads` — the caller's Thread nodes. On a shared stack, the calling
/// app's own and the stack's one Thread (registered as `aii`), whose counts are
/// the caller's lane's; everywhere else, every node, as before.
func registerThreadNodesRoute(_ router: some RouterMethods<SewnRequestContext>, _ sewn: SewnCore) {
    router.get("/v1/threads") { _, context async throws -> ThreadNodesResponse in
        let all = await sewn.nonisolatedRegistryMutator.allNodes(in: sewn.nodeScope(for: context.callerApp))
        let statsMap = await sewn.fanoutStats(app: context.callerApp)

        var totalDocumentCount = 0
        var totalGroupCount = 0

        let entries = all.map { node in
            let nodeStats: ThreadNodeStats?
            if let s = statsMap[node.threadId.uuidString] {
                nodeStats = ThreadNodeStats(s)
                totalDocumentCount += Int(s.documentCount)
                totalGroupCount    += Int(s.groupCount)
            } else {
                nodeStats = nil
            }
            return ThreadNodeEntry(
                threadId: node.threadId.uuidString,
                host: node.host,
                grpcPort: node.grpcPort,
                httpPort: node.httpPort,
                lastSeen: node.lastSeen,
                isActive: node.isActive,
                acceptingStorage: node.acceptingStorage,
                stats: nodeStats,
                app: node.app
            )
        }

        return ThreadNodesResponse(
            mothershipId: sewn.nodeId.uuidString,
            totalDocumentCount: totalDocumentCount,
            totalGroupCount: totalGroupCount,
            nodes: entries,
            enabled: !all.isEmpty
        )
    }
}
