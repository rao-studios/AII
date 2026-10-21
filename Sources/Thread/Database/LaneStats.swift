//
//  LaneStats.swift
//  Thread
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: What one lane of the index holds — documents, groups, owners, the
//        entities and relationships its documents mention, its most-mentioned
//        entities — and the same for the whole node. Behind `GET /v1/stats`, the
//        Stats RPC and the graph query's counts.
//  WHY:  Registry counts are cheap; entity and relationship counts need a pass over
//        the graph (tens of thousands of rows, each with a vector), 10–50 ms. Three
//        apps polling every few seconds would spend that for nothing, so the pass
//        runs once per change and is held for every lane, keyed by the mutators'
//        versions, and never within `debounce` of the last pass.
//  PIN:  Never triggers a save (a save rewrites the graph file). Counts are node-wide
//        facts cut to a lane: an entity two lanes mention counts in both.
//

import AII
import Foundation

struct LaneStats: Codable, Equatable, Sendable {
    struct TopEntity: Codable, Equatable, Sendable {
        let id: String
        let name: String
        let kind: String
        let mentionCount: Int

        enum CodingKeys: String, CodingKey {
            case id, name, kind
            case mentionCount = "mention_count"
        }
    }

    var lane: LaneID
    var documents: Int = 0
    var groups: Int = 0
    var owners: Int = 0
    var entities: Int = 0
    var relationships: Int = 0
    var topEntities: [TopEntity] = []

    enum CodingKeys: String, CodingKey {
        case lane, documents, groups, owners, entities, relationships
        case topEntities = "top_entities"
    }

    static let topCount = 10
}

/// The per-lane pass and its cache. A plain class under one lock: the pass runs on
/// the caller's thread under the lock, so two pollers never compute it twice.
final class LaneStatsCache: @unchecked Sendable {
    struct Key: Equatable {
        let table: UInt64
        let registry: UInt64
    }

    private struct Computed {
        let key: Key
        let at: Date
        let total: LaneStats
        let byLane: [LaneID: LaneStats]
    }

    private let lock = NSLock()
    private var computed: Computed?
    private(set) var passes = 0
    let debounce: TimeInterval

    init(debounce: TimeInterval = 5) {
        self.debounce = debounce
    }

    /// The node's stats and every lane's, computing when the stores changed and the
    /// last pass is older than `debounce`.
    func read(key: Key, registry: ThreadRegistry?, table: PartitionTable?, graph: GraphStore?,
              now: Date = Date()) -> (total: LaneStats, byLane: [LaneID: LaneStats]) {
        lock.lock()
        defer { lock.unlock() }
        if let computed, computed.key == key || now.timeIntervalSince(computed.at) < debounce {
            return (computed.total, computed.byLane)
        }
        let fresh = Self.compute(registry: registry, table: table, graph: graph)
        computed = Computed(key: key, at: now, total: fresh.total, byLane: fresh.byLane)
        passes += 1
        return fresh
    }

    /// The pass itself, pure.
    static func compute(registry: ThreadRegistry?, table: PartitionTable?, graph: GraphStore?)
        -> (total: LaneStats, byLane: [LaneID: LaneStats]) {
        var total = LaneStats(lane: .unscoped)
        total.documents = table?.keys.count ?? registry?.documentOwners.count ?? 0
        total.groups = registry?.groups.count ?? 0
        total.owners = registry?.ownersDocuments.count ?? 0
        total.entities = graph?.entities.count ?? 0
        total.relationships = graph?.relationships.count ?? 0
        total.topEntities = top(graph?.entities.values.map { $0 } ?? [])

        var byLane: [LaneID: LaneStats] = [:]
        guard let registry else { return (total, byLane) }
        for (lane, documentIds) in registry.laneDocuments where !lane.isUnscoped {
            var stats = LaneStats(lane: lane)
            stats.documents = documentIds.count
            stats.groups = registry.laneGroups[lane]?.count ?? 0
            var owners = Set<OwnerID>()
            for id in documentIds {
                for owner in registry.documentOwners[id] ?? [] { owners.insert(owner.id) }
            }
            stats.owners = owners.count
            if let graph {
                var mentioned: [Entity] = []
                for entity in graph.entities.values where !entity.documentIds.isDisjoint(with: documentIds) {
                    mentioned.append(entity)
                }
                stats.entities = mentioned.count
                stats.relationships = graph.relationships.values.reduce(0) {
                    $0 + ($1.documentIds.isDisjoint(with: documentIds) ? 0 : 1)
                }
                stats.topEntities = top(mentioned)
            }
            byLane[lane] = stats
        }
        // Lanes with groups but no documents still answer.
        for (lane, groupIds) in registry.laneGroups where !lane.isUnscoped && byLane[lane] == nil {
            var stats = LaneStats(lane: lane)
            stats.groups = groupIds.count
            byLane[lane] = stats
        }
        return (total, byLane)
    }

    private static func top(_ entities: [Entity]) -> [LaneStats.TopEntity] {
        entities
            .sorted { ($0.mentionCount, $0.name) > ($1.mentionCount, $1.name) }
            .prefix(LaneStats.topCount)
            .map { LaneStats.TopEntity(id: $0.id, name: $0.name, kind: $0.kind, mentionCount: $0.mentionCount) }
    }
}

extension Database {
    private nonisolated var laneStatsKey: LaneStatsCache.Key {
        LaneStatsCache.Key(table: tableMutator.mutationVersion, registry: registryMutator.mutationVersion)
    }

    /// One lane's stats (`.unscoped`: the whole node's).
    nonisolated func stats(lane: LaneID) -> LaneStats {
        let (total, byLane) = laneStats.read(key: laneStatsKey, registry: registry, table: table, graph: graph)
        if lane.isUnscoped { return total }
        return byLane[lane] ?? LaneStats(lane: lane)
    }

    /// Every lane's stats, by lane id, for the stack identity.
    nonisolated func statsByLane() -> [LaneID: LaneStats] {
        laneStats.read(key: laneStatsKey, registry: registry, table: table, graph: graph).byLane
    }
}
