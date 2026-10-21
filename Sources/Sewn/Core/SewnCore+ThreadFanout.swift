//
//  SewnCore+ThreadFanout.swift
//  Sewn
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Every call Sewn makes to its Thread nodes: search, index, remove,
//        library, graph, updates, stats.
//  IN:   A SewnRequest, or an explicit owner plus the caller app.
//  OUT:  Merged results from the nodes the caller may reach.
//  PIN:  Each function asks the registry for nodes in the caller's
//        `NodeScope` first and narrows from there. On a shared ~/.rao stack
//        that is the stack's one Thread (and any the app launched itself);
//        client-named thread ids only ever filter that list, so a client
//        can't name another app's node. Every request is built by
//        `ThreadFanoutRequests` and stamped with the caller's lane of the
//        index (`SewnCore.lane(for:)`), which Thread trusts on the session stream
//        alone; a caller with no lane gets no request and reaches no node.
//

import Seam
import Foundation
import AII

// MARK: - The requests, stamped with the caller's lane

/// Pure builders for every request Sewn sends a Thread. Each takes the caller's
/// lane and returns nil when there is none to stamp — on a shared stack a request
/// that lost its app files nowhere. Kept free of the actor so the stamping is
/// testable on its own.
enum ThreadFanoutRequests {
    static func search(queryText: String, request: SewnRequest, topK: Int, lane: String?) -> Thread_V1_ThreadSearchRequest? {
        guard let lane else { return nil }
        var req = Thread_V1_ThreadSearchRequest()
        req.queryText = queryText
        req.queryEmbedding = []
        req.queryEntityEmbedding = []
        req.entities = request.entities ?? request.tags ?? []
        req.ownerID = request.ownerId
        req.scope = request.scope?.rawValue ?? "global"
        req.topK = Int32(topK)
        var groupIds = request.groups?.map(\.id) ?? []
        if let gid = request.group?.id { groupIds.append(gid) }
        req.groupIds = groupIds
        req.aggregate = request.aggregate ?? false
        req.lane = lane
        return req
    }

    static func index(items: [SewnCore.BatchPutItem], request: SewnRequest, lane: String?) -> Thread_V1_ThreadIndexRequest? {
        guard let lane else { return nil }
        var req = Thread_V1_ThreadIndexRequest()
        req.ownerID = request.ownerId
        req.groupID = request.group?.id ?? ""
        req.groupLabel = request.group?.label ?? ""
        req.scope = request.scope?.rawValue ?? "personal"
        req.items = items.map { item in
            var protoItem = Thread_V1_ThreadIndexItem()
            protoItem.documentID = item.id
            protoItem.texts = item.texts
            protoItem.tags = item.tags
            protoItem.metadata = item.metadata ?? Data()
            protoItem.mediaType = item.mediaType == .image ? "image" : "text"
            if !(item.name?.isEmpty ?? true) { protoItem.name = item.name ?? "" }
            return protoItem
        }
        req.lane = lane
        return req
    }

    static func remove(documentIds: [String], ownerId: String, lane: String?) -> Thread_V1_ThreadRemoveRequest? {
        guard let lane else { return nil }
        var req = Thread_V1_ThreadRemoveRequest()
        req.ownerID = ownerId
        req.documentIds = documentIds
        req.lane = lane
        return req
    }

    static func library(ownerId: String, includeAvailable: Bool = false, limit: Int32 = 0, afterId: String = "",
                        threadId: String = "", documentIds: [String] = [], lane: String?) -> Thread_V1_ThreadLibraryRequest? {
        guard let lane else { return nil }
        var req = Thread_V1_ThreadLibraryRequest()
        req.ownerID = ownerId
        req.includeAvailable = includeAvailable
        req.limit = limit
        req.afterID = afterId
        req.threadID = threadId
        req.documentIds = documentIds
        req.lane = lane
        return req
    }

    static func documents(ownerId: String, documentIds: [String], lane: String?) -> Thread_V1_ThreadDocumentsRequest? {
        guard let lane else { return nil }
        var req = Thread_V1_ThreadDocumentsRequest()
        req.ownerID = ownerId
        req.documentIds = documentIds
        req.lane = lane
        return req
    }

    static func graph(ownerId: String, entity: String?, query: String?, kinds: [String], hops: Int, limit: Int,
                      includeDocuments: Bool, lane: String?) -> Thread_V1_ThreadGraphQueryRequest? {
        guard let lane else { return nil }
        var req = Thread_V1_ThreadGraphQueryRequest()
        req.ownerID = ownerId
        req.entity = entity ?? ""
        req.query = query ?? ""
        req.kinds = kinds
        req.hops = Int32(hops)
        req.limit = Int32(limit)
        req.includeDocuments = includeDocuments
        req.lane = lane
        return req
    }

    static func updateGroup(groupId: String, ownerId: String, access: String?, label: String?, description: String?,
                            tags: [String]?, updateMetadata: Bool, lane: String?) -> Thread_V1_ThreadUpdateGroupRequest? {
        guard let lane else { return nil }
        var req = Thread_V1_ThreadUpdateGroupRequest()
        req.ownerID = ownerId
        req.groupID = groupId
        if let access { req.access = access }
        if let label { req.label = label }
        if updateMetadata {
            req.updateMetadata = true
            req.groupDescription = description ?? ""
            req.tags = tags ?? []
        }
        req.lane = lane
        return req
    }

    static func updateDocument(documentId: String, ownerId: String, access: String?, groupId: String?,
                               lane: String?) -> Thread_V1_ThreadUpdateDocumentRequest? {
        guard let lane else { return nil }
        var req = Thread_V1_ThreadUpdateDocumentRequest()
        req.ownerID = ownerId
        req.documentID = documentId
        if let access { req.access = access }
        if let groupId { req.groupID = groupId }
        req.lane = lane
        return req
    }

    static func stats(lane: String?) -> Thread_V1_ThreadStatsRequest? {
        guard let lane else { return nil }
        var req = Thread_V1_ThreadStatsRequest()
        req.lane = lane
        return req
    }
}

// MARK: - Low-level fan-out primitives

extension SewnCore {
    /// Fan search out to the caller's active Thread nodes. Sewn passes `queryText` (raw string);
    /// each Thread embeds it locally before running its hybrid KG + PQ search.
    /// Returns the merged results plus a merged graph trace (entity matches and
    /// expansion edges unioned across nodes).
    nonisolated func fanoutSearch(
        queryText: String,
        request: SewnRequest,
        topK: Int = 3
    ) async -> (results: [Thread_V1_ThreadPartitionResult], trace: Thread_V1_ThreadGraphTrace?) {
        guard let client = _threadQueryClient as? ThreadQueryClient else { return ([], nil) }
        let nodes = await nonisolatedRegistryMutator.activeNodes(in: nodeScope(for: request.callerApp))
        guard !nodes.isEmpty,
              let req = ThreadFanoutRequests.search(queryText: queryText, request: request, topK: topK,
                                                    lane: lane(for: request.callerApp)) else { return ([], nil) }

        return await withTaskGroup(of: Thread_V1_ThreadSearchResponse?.self) { group in
            for node in nodes {
                group.addTask {
                    try? await client.search(req, thread: node)
                }
            }
            var all: [Thread_V1_ThreadPartitionResult] = []
            var matchedEntityIds = Set<String>()
            var expansionEdgeIds = Set<String>()
            var expandedDocumentCount: Int32 = 0
            var sawTrace = false
            for await response in group {
                guard let response else { continue }
                all.append(contentsOf: response.results)
                if response.hasTrace {
                    sawTrace = true
                    matchedEntityIds.formUnion(response.trace.matchedEntityIds)
                    expansionEdgeIds.formUnion(response.trace.expansionEdgeIds)
                    expandedDocumentCount += response.trace.expandedDocumentCount
                }
            }
            var mergedTrace: Thread_V1_ThreadGraphTrace?
            if sawTrace {
                var t = Thread_V1_ThreadGraphTrace()
                t.matchedEntityIds = Array(matchedEntityIds)
                t.expansionEdgeIds = Array(expansionEdgeIds)
                t.expandedDocumentCount = expandedDocumentCount
                mergedTrace = t
            }
            return (all.sorted { $0.score < $1.score }, mergedTrace)
        }
    }

    /// Route index items to a specific Thread node, or pick the first node available for storage.
    /// If `request.threadIds` is set, targets the first matching active node. Every
    /// candidate — `targetNode` included — must be in the caller's scope.
    /// Returns `(success, threadId)` — threadId is the UUID string of the node used.
    @discardableResult
    nonisolated func fanoutIndex(
        items: [SewnCore.BatchPutItem],
        request: SewnRequest,
        targetNode: ThreadNode? = nil
    ) async -> (success: Bool, threadId: String?) {
        guard let client = _threadQueryClient as? ThreadQueryClient else { return (false, nil) }
        let scope = nodeScope(for: request.callerApp)

        let node: ThreadNode
        if let targetNode {
            guard scope.admits(targetNode) else {
                logger.warning("fanoutIndex: Thread \(targetNode.threadId) is outside the caller's scope — not indexed", service: .sewn, request: request)
                return (false, nil)
            }
            node = targetNode
        } else if let ids = request.threadIds, !ids.isEmpty {
            let scopedNodes = await nonisolatedRegistryMutator.activeNodes(in: scope)
            guard let matched = scopedNodes.first(where: { ids.contains($0.threadId.uuidString) }) else {
                logger.warning("fanoutIndex: requested threadIds \(ids) not found among the caller's active nodes", service: .sewn, request: request)
                return (false, nil)
            }
            node = matched
        } else {
            guard let picked = await nonisolatedRegistryMutator.availableForStorage(in: scope).first else {
                // TODO: trigger automatic Thread spawn when no node is available for storage.
                // Sewn will eventually provision a new Thread, register it, and it will appear
                // in availableForStorage — at which point putBatch's retry loop will succeed.
                logger.warning("fanoutIndex: no Thread available for storage", service: .sewn, request: request)
                return (false, nil)
            }
            node = picked
        }

        guard let req = ThreadFanoutRequests.index(items: items, request: request, lane: lane(for: request.callerApp)) else {
            logger.warning("fanoutIndex: no lane for the caller — not indexed", service: .sewn, request: request)
            return (false, nil)
        }

        let threadIdStr = node.threadId.uuidString
        guard let resp = try? await client.index(req, thread: node) else {
            logger.warning("fanoutIndex: no response from Thread \(node.threadId) — session may have dropped", service: .sewn, request: request)
            return (false, threadIdStr)
        }
        if !resp.success {
            logger.warning("fanoutIndex: Thread \(node.threadId) signalled backpressure (success=false)", service: .sewn, request: request)
            return (false, threadIdStr)
        }
        return (true, threadIdStr)
    }

    /// Removes `documentIds` from the caller's Thread nodes.
    /// - `targetThreadIds`: when non-nil, only sends to those specific Thread UUIDs
    ///   among the caller's; when nil (default), broadcasts to all of the caller's
    ///   active nodes.
    /// - `app`: the app the removal acts for (`SewnRequest.callerApp`).
    nonisolated func fanoutRemove(
        documentIds: [String],
        ownerId: String,
        targetThreadIds: [String]? = nil,
        app: AIIApp?
    ) async {
        guard let client = _threadQueryClient as? ThreadQueryClient else { return }
        let scopedNodes = await nonisolatedRegistryMutator.activeNodes(in: nodeScope(for: app))
        let nodes: [ThreadNode]
        if let ids = targetThreadIds {
            nodes = scopedNodes.filter { ids.contains($0.threadId.uuidString) }
        } else {
            nodes = scopedNodes
        }
        guard let req = ThreadFanoutRequests.remove(documentIds: documentIds, ownerId: ownerId, lane: lane(for: app)) else { return }
        await withTaskGroup(of: Void.self) { group in
            for node in nodes {
                group.addTask {
                    _ = try? await client.remove(req, thread: node)
                }
            }
        }
    }
}

// MARK: - Library fan-out

/// Sentinel URL used in stub documents returned from paginated list responses.
/// The full URL is never needed in a list row — only the document ID — so we
/// ship only the ID and skip the URL parsing + serialization cost for every
/// document on every page.
private let stubDocumentURL = URL(string: "https://sewn.invalid")!

/// Full conversion — used for leaderboard, search, and any non-paginated path
/// where downstream code needs actual document metadata.
private func convertThreadGroup(_ pg: Thread_V1_ThreadGroup) -> SewnCore.Group {
    let docs: [SewnCore.Document] = pg.documents.map { pd in
        SewnCore.Document(
            id: pd.id,
            url: URL(string: pd.url) ?? URL(string: "file://unknown")!,
            ownerId: pd.ownerID,
            createdAt: Date(timeIntervalSince1970: TimeInterval(pd.createdAt))
        )
    }
    let access: SewnRegistry.Access? = pg.access.isEmpty ? nil
        : SewnRegistry.Access(rawValue: pg.access)
    let metadata: SewnCore.Group.Metadata? = (pg.groupDescription.isEmpty && pg.tags.isEmpty) ? nil
        : SewnCore.Group.Metadata(
            description: pg.groupDescription.isEmpty ? nil : pg.groupDescription,
            tags: Array(pg.tags)
          )
    return SewnCore.Group(
        id: pg.id,
        label: pg.label,
        ownerId: pg.ownerID,
        documents: docs,
        access: access,
        totalEarnings: pg.totalEarnings == 0 ? nil : pg.totalEarnings,
        metadata: metadata
    )
}

/// Light conversion for paginated list responses — documents are replaced with
/// ID-only stubs so we skip URL parsing and avoid serializing hundreds of URL
/// strings, ownerIds, and timestamps on every page fetch.  The stub URL is a
/// sentinel that callers use to suppress display; the real URL loads on demand
/// when the user taps into a document.
private func convertThreadGroupLight(_ pg: Thread_V1_ThreadGroup) -> SewnCore.Group {
    let stubs: [SewnCore.Document] = pg.documents.map { pd in
        SewnCore.Document(id: pd.id, url: stubDocumentURL, ownerId: "", createdAt: .distantPast)
    }
    let access: SewnRegistry.Access? = pg.access.isEmpty ? nil
        : SewnRegistry.Access(rawValue: pg.access)
    let metadata: SewnCore.Group.Metadata? = (pg.groupDescription.isEmpty && pg.tags.isEmpty) ? nil
        : SewnCore.Group.Metadata(
            description: pg.groupDescription.isEmpty ? nil : pg.groupDescription,
            tags: Array(pg.tags)
          )
    return SewnCore.Group(
        id: pg.id,
        label: pg.label,
        ownerId: pg.ownerID,
        documents: stubs,
        access: access,
        totalEarnings: pg.totalEarnings == 0 ? nil : pg.totalEarnings,
        metadata: metadata
    )
}

private func mergeThreadGroups(_ threadGroups: [SewnCore.Group], into groupMap: inout [String: SewnCore.Group]) {
    for threadGroup in threadGroups {
        if var existing = groupMap[threadGroup.id] {
            var seenIds = Set(existing.documents.map { $0.id })
            for doc in threadGroup.documents where seenIds.insert(doc.id).inserted {
                existing.documents.append(doc)
            }
            groupMap[threadGroup.id] = existing
        } else {
            groupMap[threadGroup.id] = threadGroup
        }
    }
}

extension SewnCore {
    /// Fans out gRPC Library to the caller's active Thread nodes and coalesces results.
    ///
    /// - Parameters:
    ///   - limit: When set, fetches one page of this size from each Thread using `afterId` as the
    ///     cursor. When nil, fetches all pages and returns the full library.
    ///   - afterId: Anchor cursor (group id) for the next page; empty = start of list.
    ///   - threadIds: When set, only fans out to the caller's Threads whose UUID is in this list.
    ///   - app: The app the request acts for (`SewnRequest.callerApp`).
    nonisolated func fanoutLibrary(
        ownerId: String,
        limit: Int? = nil,
        afterId: String = "",
        threadIds: [String]? = nil,
        app: AIIApp?
    ) async -> (groups: [SewnCore.Group], hasMore: Bool, nextAfterId: String) {
        guard let client = _threadQueryClient as? ThreadQueryClient else { return ([], false, "") }
        let scopedNodes = await nonisolatedRegistryMutator.activeNodes(in: nodeScope(for: app))
        let nodes: [ThreadNode]
        if let ids = threadIds, !ids.isEmpty {
            nodes = scopedNodes.filter { ids.contains($0.threadId.uuidString) }
        } else if !ownerId.isEmpty {
            nodes = await nonisolatedRegistryMutator.threadNodesForOwner(ownerId, scopedNodes: scopedNodes)
        } else {
            nodes = scopedNodes
        }
        guard !nodes.isEmpty, let lane = lane(for: app) else { return ([], false, "") }

        var groupMap: [String: SewnCore.Group] = [:]
        var hasMore = false

        if let limit {
            // Single-page fetch: one gRPC request per Thread with the caller's cursor/limit.
            await withTaskGroup(of: (groups: [SewnCore.Group], hasMore: Bool).self) { group in
                for node in nodes {
                    group.addTask {
                        guard let req = ThreadFanoutRequests.library(
                            ownerId: ownerId, includeAvailable: true, limit: Int32(limit), afterId: afterId,
                            threadId: node.threadId.uuidString, lane: lane) else { return ([], false) }
                        guard let resp = try? await client.library(req, thread: node) else { return ([], false) }
                        if !resp.groups.isEmpty && !ownerId.isEmpty {
                            await self.nonisolatedRegistryMutator.recordOwnerThread(
                                ownerId: ownerId, threadId: node.threadId
                            )
                        }
                        return (resp.groups.map(convertThreadGroupLight), resp.hasMore_p)
                    }
                }
                for await (groups, nodeHasMore) in group {
                    hasMore = hasMore || nodeHasMore
                    mergeThreadGroups(groups, into: &groupMap)
                }
            }
        } else {
            // Full multi-page fetch: loop until each Thread reports no more pages.
            let pageSize: Int32 = 200
            await withTaskGroup(of: [SewnCore.Group].self) { group in
                for node in nodes {
                    group.addTask {
                        var pageGroups: [SewnCore.Group] = []
                        var cursor = ""
                        var recorded = false
                        repeat {
                            guard let req = ThreadFanoutRequests.library(
                                ownerId: ownerId, includeAvailable: true, limit: pageSize, afterId: cursor,
                                threadId: node.threadId.uuidString, lane: lane) else { break }
                            guard let resp = try? await client.library(req, thread: node) else { break }
                            if !recorded && !resp.groups.isEmpty && !ownerId.isEmpty {
                                await self.nonisolatedRegistryMutator.recordOwnerThread(
                                    ownerId: ownerId, threadId: node.threadId
                                )
                                recorded = true
                            }
                            pageGroups.append(contentsOf: resp.groups.map(convertThreadGroup))
                            cursor = resp.groups.last?.id ?? ""
                            if !resp.hasMore_p { break }
                        } while true
                        return pageGroups
                    }
                }
                for await groups in group {
                    mergeThreadGroups(groups, into: &groupMap)
                }
            }
        }

        let sorted = Array(groupMap.values).sorted { $0.id < $1.id }
        return (sorted, hasMore, sorted.last?.id ?? "")
    }

    /// Fans out a document-ID-filtered Library request to the caller's targeted Thread nodes.
    /// Uses the Thread's reverse `documentGroups` map — no full library scan.
    /// Returns matching groups and a documentId → groupId map.
    nonisolated func fanoutLibraryByDocuments(
        ownerId: String,
        documentIds: [String],
        threadIds: [String]? = nil,
        app: AIIApp?
    ) async -> (groups: [SewnCore.Group], documentGroups: [String: String]) {
        guard let client = _threadQueryClient as? ThreadQueryClient else { return ([], [:]) }
        let scopedNodes = await nonisolatedRegistryMutator.activeNodes(in: nodeScope(for: app))
        let nodes: [ThreadNode]
        if let ids = threadIds, !ids.isEmpty {
            nodes = scopedNodes.filter { ids.contains($0.threadId.uuidString) }
        } else if !ownerId.isEmpty {
            nodes = await nonisolatedRegistryMutator.threadNodesForOwner(ownerId, scopedNodes: scopedNodes)
        } else {
            nodes = scopedNodes
        }
        guard !nodes.isEmpty, let lane = lane(for: app) else { return ([], [:]) }

        var groupMap: [String: SewnCore.Group] = [:]

        await withTaskGroup(of: [SewnCore.Group].self) { group in
            for node in nodes {
                group.addTask {
                    guard let req = ThreadFanoutRequests.library(
                        ownerId: ownerId, threadId: node.threadId.uuidString, documentIds: documentIds, lane: lane)
                    else { return [] }
                    guard let resp = try? await client.library(req, thread: node) else { return [] }
                    return resp.groups.map(convertThreadGroup)
                }
            }
            for await groups in group {
                mergeThreadGroups(groups, into: &groupMap)
            }
        }

        let sorted = Array(groupMap.values).sorted { $0.id < $1.id }

        let requestedSet = Set(documentIds)
        var documentGroupMap: [String: String] = [:]
        for group in sorted {
            for doc in group.documents where requestedSet.contains(doc.id) {
                documentGroupMap[doc.id] = group.id
            }
        }

        return (sorted, documentGroupMap)
    }
}

// MARK: - Documents fan-out

extension SewnCore {
    /// Full documents by id from the caller's targeted Thread nodes — no
    /// embedding, no search. Nil when no node was reached or every node
    /// failed; an empty array means the nodes answered without them.
    nonisolated func fanoutDocuments(
        ownerId: String,
        documentIds: [String],
        threadIds: [String]? = nil,
        app: AIIApp?
    ) async -> [Thread_V1_ThreadDocumentContent]? {
        guard let client = _threadQueryClient as? ThreadQueryClient else { return nil }
        let scopedNodes = await nonisolatedRegistryMutator.activeNodes(in: nodeScope(for: app))
        var nodes: [ThreadNode]
        if let ids = threadIds, !ids.isEmpty {
            nodes = scopedNodes.filter { ids.contains($0.threadId.uuidString) }
        } else {
            nodes = []
        }
        if nodes.isEmpty {
            nodes = await nonisolatedRegistryMutator.threadNodesForOwner(ownerId, scopedNodes: scopedNodes)
        }
        guard !nodes.isEmpty,
              let req = ThreadFanoutRequests.documents(ownerId: ownerId, documentIds: documentIds, lane: lane(for: app))
        else { return nil }

        return await withTaskGroup(of: [Thread_V1_ThreadDocumentContent]?.self) { group in
            for node in nodes {
                group.addTask { try? await client.documents(req, thread: node).documents }
            }
            var answered = false
            var documents: [Thread_V1_ThreadDocumentContent] = []
            for await result in group {
                guard let result else { continue }
                answered = true
                documents.append(contentsOf: result)
            }
            return answered ? documents : nil
        }
    }
}

// MARK: - Graph fan-out

extension SewnCore {
    /// Fans out a knowledge-graph query to the caller's active Thread nodes and merges the
    /// results: entities dedupe by id (mention counts summed, max score), relationships
    /// dedupe by id (weights summed), documents dedupe by id, stats summed.
    nonisolated func fanoutGraph(
        ownerId: String,
        entity: String? = nil,
        query: String? = nil,
        kinds: [String] = [],
        hops: Int = 1,
        limit: Int = 20,
        includeDocuments: Bool = true,
        app: AIIApp?
    ) async -> Thread_V1_ThreadGraphQueryResponse {
        var merged = Thread_V1_ThreadGraphQueryResponse()
        guard let client = _threadQueryClient as? ThreadQueryClient else { return merged }
        let nodes = await nonisolatedRegistryMutator.activeNodes(in: nodeScope(for: app))
        guard !nodes.isEmpty,
              let req = ThreadFanoutRequests.graph(ownerId: ownerId, entity: entity, query: query, kinds: kinds, hops: hops,
                                                   limit: limit, includeDocuments: includeDocuments, lane: lane(for: app))
        else { return merged }

        let responses = await withTaskGroup(of: Thread_V1_ThreadGraphQueryResponse?.self) { group in
            for node in nodes {
                group.addTask {
                    try? await client.graph(req, thread: node)
                }
            }
            var all: [Thread_V1_ThreadGraphQueryResponse] = []
            for await response in group {
                if let response { all.append(response) }
            }
            return all
        }

        var entitiesById: [String: Thread_V1_ThreadGraphEntity] = [:]
        var relationshipsById: [String: Thread_V1_ThreadGraphRelationship] = [:]
        var documentsById: [String: Thread_V1_ThreadGraphDocument] = [:]
        var stats = Thread_V1_ThreadGraphStats()

        for response in responses {
            for e in response.entities {
                if var existing = entitiesById[e.id] {
                    existing.mentionCount += e.mentionCount
                    existing.score = max(existing.score, e.score)
                    existing.documentIds = Array(Set(existing.documentIds + e.documentIds)).sorted()
                    entitiesById[e.id] = existing
                } else {
                    entitiesById[e.id] = e
                }
            }
            for r in response.relationships {
                if var existing = relationshipsById[r.id] {
                    existing.weight += r.weight
                    existing.documentIds = Array(Set(existing.documentIds + r.documentIds)).sorted()
                    relationshipsById[r.id] = existing
                } else {
                    relationshipsById[r.id] = r
                }
            }
            for d in response.documents where documentsById[d.id] == nil {
                documentsById[d.id] = d
            }
            stats.entityCount += response.stats.entityCount
            stats.relationshipCount += response.stats.relationshipCount
        }

        merged.entities = entitiesById.values.sorted { $0.score > $1.score }
        merged.relationships = relationshipsById.values.sorted { $0.weight > $1.weight }
        merged.documents = documentsById.values.sorted { $0.id < $1.id }
        merged.stats = stats
        return merged
    }
}

// MARK: - Update fan-out

extension SewnCore {
    /// Broadcasts a group access/label/metadata update to the caller's active Thread nodes.
    /// Returns true if at least one Thread confirmed success.
    @discardableResult
    nonisolated func fanoutUpdateGroup(
        groupId: String,
        ownerId: String,
        access: String?,
        label: String?,
        description: String?,
        tags: [String]?,
        updateMetadata: Bool = false,
        app: AIIApp?
    ) async -> Bool {
        guard let client = _threadQueryClient as? ThreadQueryClient else { return false }
        let nodes = await nonisolatedRegistryMutator.activeNodes(in: nodeScope(for: app))
        guard !nodes.isEmpty,
              let req = ThreadFanoutRequests.updateGroup(groupId: groupId, ownerId: ownerId, access: access, label: label,
                                                         description: description, tags: tags, updateMetadata: updateMetadata,
                                                         lane: lane(for: app))
        else { return false }

        return await withTaskGroup(of: Bool.self) { group in
            for node in nodes {
                group.addTask {
                    (try? await client.updateGroup(req, thread: node))?.success ?? false
                }
            }
            var anySuccess = false
            for await success in group { anySuccess = anySuccess || success }
            return anySuccess
        }
    }

    /// Broadcasts a document access/group update to the caller's active Thread nodes.
    /// Returns true if at least one Thread confirmed success.
    @discardableResult
    nonisolated func fanoutUpdateDocument(
        documentId: String,
        ownerId: String,
        access: String?,
        groupId: String?,
        app: AIIApp?
    ) async -> Bool {
        guard let client = _threadQueryClient as? ThreadQueryClient else { return false }
        let nodes = await nonisolatedRegistryMutator.activeNodes(in: nodeScope(for: app))
        guard !nodes.isEmpty,
              let req = ThreadFanoutRequests.updateDocument(documentId: documentId, ownerId: ownerId, access: access,
                                                            groupId: groupId, lane: lane(for: app))
        else { return false }

        return await withTaskGroup(of: Bool.self) { group in
            for node in nodes {
                group.addTask {
                    (try? await client.updateDocument(req, thread: node))?.success ?? false
                }
            }
            var anySuccess = false
            for await success in group { anySuccess = anySuccess || success }
            return anySuccess
        }
    }

    /// Fetches registry stats from the caller's active Thread nodes in parallel.
    /// Returns a map of threadId (UUID string) → stats response.
    nonisolated func fanoutStats(app: AIIApp?) async -> [String: Thread_V1_ThreadStatsResponse] {
        guard let client = _threadQueryClient as? ThreadQueryClient else { return [:] }
        let nodes = await nonisolatedRegistryMutator.activeNodes(in: nodeScope(for: app))
        guard !nodes.isEmpty, let req = ThreadFanoutRequests.stats(lane: lane(for: app)) else { return [:] }

        return await withTaskGroup(of: (String, Thread_V1_ThreadStatsResponse?).self) { group in
            for node in nodes {
                group.addTask {
                    let resp = try? await client.stats(req, thread: node)
                    return (node.threadId.uuidString, resp)
                }
            }
            var result: [String: Thread_V1_ThreadStatsResponse] = [:]
            for await (threadId, resp) in group {
                if let resp { result[threadId] = resp }
            }
            return result
        }
    }
}
