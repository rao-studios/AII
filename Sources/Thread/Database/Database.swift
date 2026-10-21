//
//  Database.swift
//  Thread
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//

import AII
import Foundation
import Logging

struct DatabaseConfig {}

actor Database {
    internal let logger: ThreadLogger
    internal let baseLogger: Logger
    nonisolated internal let sinatra: Sinatra
    internal let tableMutator: TableMutator
    internal let registryMutator: RegistryMutator
    let documentCache: DocumentCache

    let nodeId: UUID

    nonisolated(unsafe) var initializationTask: Task<Void, Never>!

    private enum WriteJob {
        case put([Database.BatchPutItem], DatabaseRequest)
        case removeBatch([(documentId: String, ownerId: String)], lane: LaneID)
        case removeAll(ownerId: String, request: DatabaseRequest, CheckedContinuation<Int, Never>)
        case removeGroups([GroupID], ownerId: String, lane: LaneID, CheckedContinuation<Database.GroupRemoval, Never>)
    }

    /// Per-lane counts, recomputed when the stores change (LaneStats.swift).
    nonisolated let laneStats = LaneStatsCache()
    private var pending: [WriteJob] = []
    private var isProcessing = false

    /// Numbers each filing in the order Index answered it (Database+Put.swift), without
    /// awaiting the actor: enrichment runs detached, so filings can reach the queue out
    /// of order, and the numbers put them back in order.
    nonisolated let putSequencer = PutSequencer()
    /// The newest filing number applied to each document id since this process started.
    var appliedPutSequence: [DocumentID: UInt64] = [:]

    /// The embedder this process runs, as it would stamp the table (EmbedderStamp.swift).
    var runningEmbedder: EmbedderStamp?
    /// How the table's vectors relate to it; `nil` until reconciled.
    var indexState: IndexState?

    init(nodeId: UUID? = nil, config: DatabaseConfig = DatabaseConfig()) {
        var baseLogger = Logger(label: "thread-logger")
        baseLogger.logLevel = .debug
        self.baseLogger = baseLogger
        self.logger = ThreadLogger(baseLogger)
        self.sinatra = Sinatra(logger: baseLogger)
        self.documentCache = DocumentCache()

        let identity = NodeIdentity.load(override: nodeId, logger: baseLogger)
        self.nodeId = identity.nodeId

        self.tableMutator = TableMutator(nodeId: identity.nodeId, logger: ThreadLogger(baseLogger))
        self.registryMutator = RegistryMutator(nodeId: identity.nodeId, logger: ThreadLogger(baseLogger))
        self.initializationTask = Task { [self] in
            await self.startup()
        }
    }

    func shutdown() async {
        // Drain any pending puts before flushing to disk. shutdown() and drain() share
        // the Database actor; yielding here lets drain() process its queue so
        // flushAllForShutdown() saves the fully up-to-date snapshot.
        while isProcessing || !pending.isEmpty {
            await Task.yield()
        }
        await tableMutator.flushAllForShutdown()
        await registryMutator.flushForShutdown()
    }

    /// Clears one lane of the index: its documents go through the normal removal
    /// path (table entry, graph provenance, files), so entities shared with another
    /// lane survive; the embedder stamp is renewed only if the table ends empty.
    /// `.unscoped` — a Thread with no lanes — clears everything, as `clearAll`.
    func clear(lane: LaneID) async -> (documents: Int, entities: Int) {
        if lane.isUnscoped { return await clearAll() }
        while isProcessing || !pending.isEmpty {
            await Task.yield()
        }
        let entitiesBefore = graph?.entities.count ?? 0
        let removed = await registryMutator.removeLane(lane)
        for documentId in removed {
            documentCache.evict(documentId)
            documentStore(for: documentId).purge()
            partitionStore(for: documentId).purge()
        }
        await tableMutator.removeAll(documentIds: removed, request: DatabaseRequest(ownerId: "", lane: lane))
        if table?.keys.isEmpty ?? true { restampAfterClear() }
        let entitiesAfter = graph?.entities.count ?? 0
        logger.info(
            "Clear",
            "🧹 Cleared lane \(lane) — \(removed.count) document(s), \(max(0, entitiesBefore - entitiesAfter)) entity(ies) removed",
            service: .database
        )
        return (removed.count, max(0, entitiesBefore - entitiesAfter))
    }

    /// Clears this node's entire database — partition table, graph, registry,
    /// and document cache — persisting the empty stores immediately. Shared
    /// content-addressed files under `documents/` are left in place (other
    /// co-located nodes may reference them; re-ingest reuses or rewrites them).
    /// Returns the removed counts for the caller's response. Every lane goes: on a
    /// shared stack only the stack identity may ask for it.
    func clearAll() async -> (documents: Int, entities: Int) {
        // Drain pending writes first so nothing re-populates after the wipe.
        while isProcessing || !pending.isEmpty {
            await Task.yield()
        }
        let documentCount = table?.keys.count ?? 0
        let entityCount = graph?.entities.count ?? 0
        await tableMutator.clearAll()
        await registryMutator.clearAll()
        documentCache.seed([:])
        restampAfterClear()
        logger.info(
            "Clear",
            "🧹 Cleared node database — \(documentCount) document(s), \(entityCount) entity(ies) removed",
            service: .database
        )
        return (documentCount, entityCount)
    }
}

extension Database {
    func startup() async {
        initializeRegistry()
        initializeTable()
    }
}

extension Database {
    nonisolated func user(for id: String) -> Database.User {
        Database.User(groups: groups(for: id))
    }
}

extension Database {
    nonisolated var nonisolatedRegistryMutator: RegistryMutator { registryMutator }
    nonisolated var nonisolatedTableMutator: TableMutator { tableMutator }
}

extension Database {
    private static let maxCoalesceItems = 100

    func enqueuePut(_ items: [Database.BatchPutItem], request: DatabaseRequest) {
        enqueue(.put(items, request))
    }

    func enqueueRemoveBatch(_ items: [(documentId: String, ownerId: String)], lane: LaneID = .unscoped) {
        enqueue(.removeBatch(items, lane: lane))
    }

    /// Unlinks every document `ownerId` holds in the request's lane; see
    /// `RegistryMutator.removeAll` for why the lane is part of it.
    func removeAll(ownerId: String, request: DatabaseRequest) async -> Int {
        await withCheckedContinuation { continuation in
            enqueue(.removeAll(ownerId: ownerId, request: request, continuation))
        }
    }

    /// Deletes the groups `ownerId` owns in `lane` and what is filed in them; see
    /// `RegistryMutator.removeGroups`. Queued behind the writes before it — a put into
    /// one of the groups lands first and goes with it — and answered once done.
    func removeGroups(_ groupIds: [GroupID], ownerId: String, lane: LaneID) async -> Database.GroupRemoval {
        await withCheckedContinuation { continuation in
            enqueue(.removeGroups(groupIds, ownerId: ownerId, lane: lane, continuation))
        }
    }

    private func enqueue(_ job: WriteJob) {
        pending.append(job)
        guard !isProcessing else { return }
        isProcessing = true
        Task { await self.drain() }
    }

    private func drain() async {
        while !pending.isEmpty {
            if case .put(let firstItems, let baseReq) = pending[0] {
                var merged   = firstItems
                var consumed = 1
                while consumed < pending.count && merged.count < Self.maxCoalesceItems {
                    guard case .put(let nextItems, let nextReq) = pending[consumed],
                          nextReq.ownerId == baseReq.ownerId,
                          nextReq.lane == baseReq.lane,
                          nextReq.group?.id == baseReq.group?.id else { break }
                    merged.append(contentsOf: nextItems)
                    consumed += 1
                }
                pending.removeFirst(consumed)
                await execute(.put(merged, baseReq))
            } else {
                let job = pending.removeFirst()
                await execute(job)
            }
        }
        isProcessing = false
    }

    private func execute(_ job: WriteJob) async {
        switch job {
        case .put(let items, let request):
            await putBatch(items, request: request)
        case .removeBatch(let items, let lane):
            await _removeBatch(items: items, lane: lane)
        case .removeAll(let ownerId, let request, let continuation):
            let count = await _removeAll(ownerId: ownerId, request: request)
            continuation.resume(returning: count)
        case .removeGroups(let groupIds, let ownerId, let lane, let continuation):
            continuation.resume(returning: await _removeGroups(groupIds, ownerId: ownerId, lane: lane))
        }
    }
}
