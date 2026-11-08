//
//  CodeRelationQueue.swift
//  Thread
//
//  Created by Ritesh Pakala on 11/07/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The code relations still to read, in one line: every filing that asks `relate_code` adds
//        its code items here, and one worker reads them in order (CodeRelationEnrichment) and
//        re-applies each answer behind the put (Database.relate).
//  IN:   Filings (ThreadQueryServiceImpl.index), the extractor (through its gate), the embedder.
//  OUT:  Readings landing on their documents; `pending` for /v1/graph/extractor; `clear` when
//        readings are switched off.
//  PIN:  ONE WORKER. Until 2026-11-07 each filing started a reading loop of its own, so a refile of
//        five hundred cards in batches of eight ran sixty loops at once. Now filings only enqueue.
//  PIN:  THE NEWEST FILING IS THE ONE TO READ. A document filed again while it waits keeps its
//        place and takes the newer item. The line holds at most `capacity` items; past it the
//        oldest waiting go, counted in `dropped`, and a later filing of them reads them again.
//  PIN:  NOT KEPT ACROSS A RESTART. Waiting readings live in memory; a document whose reading was
//        lost gets one the next time its filer sends it again.
//

import Foundation
import Logging

actor CodeRelationQueue {
    static let defaultCapacity = 20_000

    private let database: Database
    private let extractor: any GraphExtracting
    private let embedder: any EmbeddingProviding
    private let accepts: @Sendable () async -> Bool
    private let capacity: Int
    private let logger: Logger

    private var order: [DocumentID] = []
    private var head = 0
    private var waiting: [DocumentID: (item: Database.BatchPutItem, request: DatabaseRequest)] = [:]
    private var worker: Task<Void, Never>?
    private(set) var read = 0
    private(set) var dropped = 0

    /// `accepts` says whether readings are on now (the extractor gate's switch); off, filings enqueue nothing.
    init(database: Database, extractor: any GraphExtracting, embedder: any EmbeddingProviding,
         capacity: Int = CodeRelationQueue.defaultCapacity,
         accepts: @escaping @Sendable () async -> Bool = { true }) {
        self.database = database
        self.extractor = extractor
        self.embedder = embedder
        self.capacity = max(1, capacity)
        self.accepts = accepts
        var logger = Logger(label: "thread-relations")
        logger.logLevel = .info
        self.logger = logger
    }

    /// Readings waiting, not counting the one being read.
    var pending: Int { waiting.count }

    /// Adds a filing's code items; a document already waiting takes the newer item and keeps its place.
    func enqueue(_ items: [Database.BatchPutItem], request: DatabaseRequest) async {
        let code = items.filter { $0.mediaType == .code }
        guard !code.isEmpty, await accepts() else { return }
        for item in code {
            if waiting[item.id] == nil { order.append(item.id) }
            waiting[item.id] = (item, request)
        }
        trimToCapacity()
        startWorker()
    }

    /// Lets every waiting reading go (readings switched off); returns how many went.
    @discardableResult
    func clear() -> Int {
        let count = waiting.count
        waiting.removeAll()
        order.removeAll()
        head = 0
        return count
    }

    /// Waits until every reading enqueued so far is done (tests).
    func drained() async {
        while let worker { await worker.value }
    }

    private func trimToCapacity() {
        var over = waiting.count - capacity
        guard over > 0 else { return }
        let before = dropped
        while over > 0, head < order.count {
            let id = order[head]
            head += 1
            if waiting.removeValue(forKey: id) != nil {
                dropped += 1
                over -= 1
            }
        }
        compact()
        logger.warning("Code relations: \(dropped - before) waiting reading(s) dropped, the line holds \(capacity)")
    }

    private func next() -> (item: Database.BatchPutItem, request: DatabaseRequest)? {
        while head < order.count {
            let id = order[head]
            head += 1
            if let entry = waiting.removeValue(forKey: id) {
                compact()
                return entry
            }
        }
        order.removeAll()
        head = 0
        return nil
    }

    /// Keeps the line's array from growing without bound as readings are taken off its front.
    private func compact() {
        guard head > 1_024, head * 2 > order.count else { return }
        order.removeFirst(head)
        head = 0
    }

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task.detached(priority: .background) { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while let entry = next() {
            await database.relate(entry.item, extractor: extractor, embedder: embedder, request: entry.request)
            read += 1
        }
        worker = nil
    }
}
