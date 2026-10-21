//
//  Library.swift
//  Thread
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//

import AII
import Hummingbird

private struct LibraryRequest: Codable {
    let ownerId: String
    let includeAvailable: Bool?
    enum CodingKeys: String, CodingKey {
        case ownerId = "owner_id"
        case includeAvailable = "include_available"
    }
}

private struct LibraryDocumentRequest: Codable {
    let documentId: String
    enum CodingKeys: String, CodingKey {
        case documentId = "document_id"
    }
}

struct LibraryResponse: ResponseCodable {
    let groups: [Database.Group]
}

func registerLibraryRoute(_ app: some RouterMethods<ThreadRequestContext>, _ database: Database,
                          resolver: LaneResolver = .unscoped) {
    app.post("/v1/library") { request, context async throws -> LibraryResponse in
        let body = try await request.decode(as: LibraryRequest.self, context: context)
        let lane = try resolver.scope(identity: context.callerIdentity).filter ?? .unscoped
        var groups = database.groups(for: body.ownerId, lane: lane)
        if body.includeAvailable == true {
            let available = database.availableGroups(lane: lane)
            var seen = Set(groups.map(\.id))
            for g in available where seen.insert(g.id).inserted {
                groups.append(g)
            }
        }
        return LibraryResponse(groups: groups)
    }

    app.post("/v1/library/document") { request, context async throws -> LibraryResponse in
        let body = try await request.decode(as: LibraryDocumentRequest.self, context: context)
        let lane = try resolver.scope(identity: context.callerIdentity).filter ?? .unscoped
        guard let registry = database.registry, registry.isReadable(body.documentId, from: lane) else {
            return LibraryResponse(groups: [])
        }
        let groupIds = (registry.documentGroups[body.documentId] ?? []).filter { registry.isGroupReadable($0, from: lane) }
        let groups = groupIds.compactMap { database.buildGroup(groupId: $0, registry: registry) }
        return LibraryResponse(groups: groups)
    }

    // Destructive. An app clears its own lane: its documents and groups go through
    // the normal removal path, other lanes are untouched. `{"all": true}` wipes the
    // whole index — table, graph, registry — and re-stamps it for the running
    // embedder (the way out of an embedder mismatch); on a shared stack only the
    // stack identity may ask for that. Requires an explicit confirmation flag so no
    // client can trip it by accident.
    app.post("/v1/clear") { request, context async throws -> ClearResponse in
        let body = try await request.decode(as: ClearRequest.self, context: context)
        guard body.confirm == true else {
            throw HTTPError(.badRequest, message: #"Pass {"confirm": true} to clear this node's database."#)
        }
        let scope = try resolver.scope(identity: context.callerIdentity)
        let removed: (documents: Int, entities: Int)
        if body.all == true {
            guard scope == .all || !resolver.isMultiApp else {
                throw HTTPError(.forbidden, message: "Only the stack identity clears every lane; an app clears its own.")
            }
            removed = await database.clearAll()
        } else {
            guard let lane = scope.writeLane else {
                throw HTTPError(.badRequest, message: #"The stack identity has no lane of its own: pass {"all": true} to clear every lane."#)
            }
            removed = await database.clear(lane: lane)
        }
        return ClearResponse(cleared: true,
                             documents: removed.documents,
                             entities: removed.entities)
    }
}

private struct ClearRequest: Codable {
    let confirm: Bool?
    /// Every lane, not just the caller's.
    let all: Bool?
}

struct ClearResponse: ResponseCodable {
    let cleared: Bool
    let documents: Int
    let entities: Int
}
