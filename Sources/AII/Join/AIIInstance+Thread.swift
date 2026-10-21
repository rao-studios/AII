//
//  AIIInstance+Thread.swift
//  AII
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Remembering, recalling and forgetting records in the app's lane of Thread.
//  IN:   The app's AIIRecordable values; a question; ids and groups to forget.
//  OUT:  How many records Thread accepted; hits with their records; what was forgotten.
//  PIN:  Each value becomes an AIIDocument, filed by AIIDocument.indexRequests: one request
//        per group, split by size. Thread answers Index before it has filed what it
//        accepted, so `remember` reads the documents back until each carries the metadata
//        just sent: when it returns, `recall` finds this version, re-remembered ids
//        included. Calls to `remember` run one at a time, so two of one id can't interleave.
//        Supersession removes the record a new one replaces only after that, never first: a
//        group lives while it holds documents, so removing first could empty it and lose
//        the label, access and metadata set on it. A record keeps the group it was first
//        filed in; to move one, forget it and remember it. Recall asks for each hit's
//        metadata and own url, and decodes the envelope; filtering by kind happens here,
//        from a wider search (Thread filters by owner, group and media type only). Nothing
//        ever sends an empty Remove. Sewn's memory groups are app-scoped:
//        `<app>-memory-<owner>` and `<app>-resonance-<owner>`.
//

#if os(macOS)
import Foundation
import GRPCCore
import Seam

extension AIIInstance {

    // MARK: - Remembering

    /// Files each value in the app's lane, waits until Thread has filed this version of
    /// each (so `recall` finds them), then removes what each supersedes. Returns how many
    /// documents Thread accepted.
    @discardableResult
    public func remember(_ values: [any AIIRecordable]) async throws -> Int {
        guard !values.isEmpty else { return 0 }
        try requireJoined()
        let previous = rememberChain
        let work = Task<Int, Error> { [previous] in
            _ = await previous?.result
            return try await self.file(values)
        }
        rememberChain = Task { _ = await work.result }
        return try await work.value
    }

    private func file(_ values: [any AIIRecordable]) async throws -> Int {
        let now = Date()
        let documents = try values.map { try $0.document(app: app, now: now) }
        let owner = self.owner
        var filed = 0
        for request in try AIIDocument.indexRequests(documents, owner: owner) {
            filed += Int(try await call { [request] in try await self.wire.index(request) }.indexedCount)
        }
        var expected: [String: Data] = [:]
        for document in documents { expected[document.documentID] = try document.metadata() }
        try await awaitFiling(expected, owner: owner)
        let replaced = documents.compactMap { document -> String? in
            guard let old = document.record.supersedes, old != document.record.id else { return nil }
            return AIIRecord.documentID(app: app, kind: document.record.kind, id: old)
        }
        try await remove(documentIDs: replaced)
        return filed
    }

    /// Reads the documents back until each carries the metadata it was just filed with, or
    /// the filing timeout passes.
    private func awaitFiling(_ expected: [String: Data], owner: AIIOwner) async throws {
        var request = Thread_V1_ThreadDocumentsRequest()
        request.ownerID = owner.rawValue
        request.documentIds = expected.keys.sorted()
        let deadline = ContinuousClock.now + filingTimeout
        while true {
            let found = try await call { [request] in try await self.wire.documents(request) }
            let filed = Dictionary(found.documents.map { ($0.id, $0.metadata) }, uniquingKeysWith: { first, _ in first })
            if expected.allSatisfy({ filed[$0.key] == $0.value }) { return }
            guard ContinuousClock.now < deadline else {
                throw AIIInstanceError.notReady("Thread accepted \(expected.count) records but hasn't filed them yet; remember them again")
            }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    // MARK: - Recalling

    /// The app's records of `T`'s kind closest to `query`, as `T`.
    public func recall<T: AIIRecordable>(_ query: String, as type: T.Type, in groups: [String]? = nil,
                                         topK: Int = 8) async throws -> [AIIRecall.Match<T>] {
        let found = try await search(query, in: groups, topK: min(topK * 3, 64))
        var matches: [AIIRecall.Match<T>] = []
        for hit in found.hits where matches.count < topK {
            guard let record = hit.record, record.app == app, let value = try record.value(as: T.self) else { continue }
            matches.append(AIIRecall.Match(value: value, hit: hit))
        }
        return matches
    }

    /// The hits closest to `query` in the app's lane — its records of any type, and what
    /// Sewn wrote back from its conversations (kind `memory`).
    public func recall(_ query: String, in groups: [String]? = nil, kinds: [AIIRecord.Kind]? = nil,
                       topK: Int = 8) async throws -> AIIRecall {
        guard let kinds else { return try await search(query, in: groups, topK: topK) }
        let found = try await search(query, in: groups, topK: min(topK * 3, 64))
        let hits = found.hits.filter { hit in hit.record.map { kinds.contains($0.kind) } ?? false }
        return AIIRecall(hits: Array(hits.prefix(topK)), trace: found.trace)
    }

    private func search(_ query: String, in groups: [String]?, topK: Int) async throws -> AIIRecall {
        try requireJoined()
        var request = Thread_V1_ThreadSearchRequest()
        request.ownerID = owner.rawValue
        request.queryText = query
        request.scope = "personal"
        request.topK = Int32(max(topK, 1))
        if let groups {
            request.groupIds = groups.map { AIIRecord.groupID(app: app, group: $0) }
        } else {
            request.aggregate = true
        }
        request.includeMetadata = true
        let response = try await call { [request] in try await self.wire.search(request) }
        let hits = response.results.map { result in
            AIIRecall.Hit(documentID: result.documentID, partitionID: result.partitionID, text: result.text,
                          distance: result.score, name: result.name.isEmpty ? nil : result.name,
                          groupID: result.groupID.isEmpty ? nil : result.groupID,
                          record: AIIRecord.decode(result.metadata), url: result.url.isEmpty ? nil : result.url)
        }
        let trace = AIIRecall.Trace(matchedEntityNames: response.trace.matchedEntityNames,
                                    expandedDocumentCount: Int(response.trace.expandedDocumentCount))
        return AIIRecall(hits: hits, trace: trace)
    }

    // MARK: - Forgetting

    /// Removes these records from the app's lane.
    public func forget(_ values: [any AIIRecordable]) async throws {
        try await remove(documentIDs: values.map { AIIRecord.documentID(app: app, kind: type(of: $0).kind, id: $0.recordID) })
    }

    /// Removes the documents behind these hits (`AIIRecall.Hit.documentID`).
    public func forget(documentIDs: [String]) async throws {
        try await remove(documentIDs: documentIDs)
    }

    /// Deletes whole groups, by the app's ids for them, and every record filed in them.
    @discardableResult
    public func forget(groups: [String]) async throws -> Forgotten {
        let prefix = "\(app.rawValue)-"
        let removed = try await removeGroups(groups.map { AIIRecord.groupID(app: app, group: $0) })
        return Forgotten(groups: removed.removedGroupIds.map { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : $0 },
                         documentCount: Int(removed.removedDocumentCount))
    }

    /// Deletes what Sewn wrote back from this app's conversations: the summaries and recap
    /// (`<app>-memory-<owner>`) and the resonant passages (`<app>-resonance-<owner>`).
    @discardableResult
    public func forgetMemory() async throws -> Forgotten {
        let owner = self.owner.rawValue
        let removed = try await removeGroups(["memory", "resonance"].map { "\(app.rawValue)-\($0)-\(owner)" })
        let prefix = "\(app.rawValue)-"
        let suffix = "-\(owner)"
        return Forgotten(groups: removed.removedGroupIds.map { id in
            var name = id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : id
            if name.hasSuffix(suffix) { name.removeLast(suffix.count) }
            return name
        }, documentCount: Int(removed.removedDocumentCount))
    }

    private func remove(documentIDs: [String]) async throws {
        // Empty would mean every document the owner holds: never send it.
        guard !documentIDs.isEmpty else { return }
        try requireJoined()
        var request = Thread_V1_ThreadRemoveRequest()
        request.ownerID = owner.rawValue
        request.documentIds = documentIDs
        _ = try await call { [request] in try await self.wire.remove(request) }
    }

    private func removeGroups(_ groupIDs: [String]) async throws -> Thread_V1_ThreadRemoveGroupsResponse {
        guard !groupIDs.isEmpty else { return Thread_V1_ThreadRemoveGroupsResponse() }
        try requireJoined()
        var request = Thread_V1_ThreadRemoveGroupsRequest()
        request.ownerID = owner.rawValue
        request.groupIds = groupIDs
        return try await call { [request] in try await self.wire.removeGroups(request) }
    }

    // MARK: - Calls

    private func call<R: Sendable>(_ body: @Sendable () async throws -> R) async throws -> R {
        do {
            return try await body()
        } catch let error as RPCError where error.code == .unavailable {
            throw AIIInstanceError.notReady(error.message)
        } catch let error as RPCError {
            throw AIIInstanceError.refused(code: "\(error.code)", message: error.message)
        }
    }
}
#endif
