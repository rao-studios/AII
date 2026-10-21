//
//  Stats.swift
//  Sewn
//
//  Created by Ritesh Pakala on 05/12/26.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation
import Hummingbird
import HTTPTypes
import AII
import Seam

/// One lane's counts as Thread reports them (`ThreadLaneStats`).
struct LaneStatsInfo: Codable, Equatable {
    let lane: String
    let documents: Int
    let groups: Int
    let owners: Int
    let entities: Int
    let relationships: Int
}

struct StatsResponse: Codable, Equatable {
    let publicDocumentCount: Int
    let publicGroupCount: Int
    /// The caller's lane, when the stack has lanes.
    let lane: String?
    /// The caller's lane's counts, summed over its Thread nodes.
    let documents: Int
    let groups: Int
    let owners: Int
    /// Every lane — only when a node answered with them (the stack identity).
    let lanes: [LaneStatsInfo]?

    enum CodingKeys: String, CodingKey {
        case publicDocumentCount, publicGroupCount, lane, documents, groups, owners, lanes
    }
}

/// The reduction of per-node stats into one answer, pure for the tests.
enum SewnStats {
    static func reduce(_ byNode: [String: Thread_V1_ThreadStatsResponse], lane: String?,
                       publicDocumentCount: Int, publicGroupCount: Int) -> StatsResponse {
        var documents = 0, groups = 0, owners = 0
        var lanes: [String: LaneStatsInfo] = [:]
        for response in byNode.values {
            documents += Int(response.documentCount)
            groups += Int(response.groupCount)
            owners = max(owners, Int(response.ownerCount))
            for stats in response.lanes {
                let merged = LaneStatsInfo(
                    lane: stats.lane,
                    documents: (lanes[stats.lane]?.documents ?? 0) + Int(stats.documents),
                    groups: (lanes[stats.lane]?.groups ?? 0) + Int(stats.groups),
                    owners: max(lanes[stats.lane]?.owners ?? 0, Int(stats.owners)),
                    entities: (lanes[stats.lane]?.entities ?? 0) + Int(stats.entities),
                    relationships: (lanes[stats.lane]?.relationships ?? 0) + Int(stats.relationships))
                lanes[stats.lane] = merged
            }
        }
        return StatsResponse(
            publicDocumentCount: publicDocumentCount, publicGroupCount: publicGroupCount,
            lane: (lane?.isEmpty ?? true) ? nil : lane,
            documents: documents, groups: groups, owners: owners,
            lanes: lanes.isEmpty ? nil : lanes.values.sorted { $0.lane < $1.lane })
    }
}

private actor StatsRateLimiter {
    private struct Window {
        var count: Int
        var windowStart: Date
    }

    private var windows: [String: Window] = [:]
    private let limit: Int
    private let windowSeconds: TimeInterval

    init(limit: Int = 10, windowSeconds: TimeInterval = 60) {
        self.limit = limit
        self.windowSeconds = windowSeconds
    }

    func allow(ip: String) -> Bool {
        let now = Date()
        if let existing = windows[ip], now.timeIntervalSince(existing.windowStart) < windowSeconds {
            if existing.count >= limit { return false }
            windows[ip]!.count += 1
        } else {
            windows[ip] = Window(count: 1, windowStart: now)
        }
        return true
    }
}

func registerStatsRoute(_ router: some RouterMethods<SewnRequestContext>, _ sewn: SewnCore) {
    let limiter = StatsRateLimiter()

    router.get("/v1/stats") { request, context async throws -> StatsResponse in
        let ip = request.headers[HTTPField.Name("X-Forwarded-For")!]?
            .split(separator: ",").first
            .map { String($0).trimmingCharacters(in: CharacterSet.whitespaces) }
            ?? context.remoteAddress?.ipAddress
            ?? "unknown"

        // Per app as well as per address: on a shared stack every app calls
        // from 127.0.0.1, and one app's polling must not use up another's.
        let app = context.callerApp
        guard await limiter.allow(ip: "\(app?.rawValue ?? "-")|\(ip)") else {
            throw HTTPError(.tooManyRequests)
        }

        let (groups, _, _) = await sewn.fanoutLibrary(ownerId: "", app: app)
        let publicGroups = groups.filter { $0.access == .available }
        let groupCount    = publicGroups.count
        let documentCount = publicGroups.reduce(0) { $0 + $1.documents.count }
        // The caller's lane of the index: Thread answers for the lane Sewn stamped.
        let byNode = await sewn.fanoutStats(app: app)
        return SewnStats.reduce(byNode, lane: sewn.lane(for: app),
                                publicDocumentCount: documentCount, publicGroupCount: groupCount)
    }
}
