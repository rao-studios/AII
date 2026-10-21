//
//  Database.Request.swift
//  Thread
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//

import AII
import Foundation

struct DatabaseRequest: Codable {
    let ownerId: String
    let group: Database.Group?
    let groups: [Database.Group]?
    /// Query entity terms for graph matching. `tags` is kept as a legacy alias;
    /// consumers should read `entities ?? tags`.
    let entities: [String]?
    let tags: [String]?
    let aggregate: Bool?
    let scope: DatabaseRequestScope?
    let requestID: String?
    /// How the query is read. `.code` selects the identifier instrument and returns
    /// only code partitions; `.text` returns only text partitions; nil is the search
    /// as it was before the field existed.
    let mediaType: MediaType?
    /// The most results to return, across documents. Nil or zero is unlimited.
    let topK: Int?
    /// The lane of the index this request reads and writes: the caller's app's,
    /// derived by the server from the secret that matched — never decoded from a
    /// body (`init(from:)` leaves it `.unscoped`; the route stamps it with
    /// `scoped(to:)`). `.unscoped` reads everything and files under no lane: the
    /// state of a Thread running open or for one app alone.
    let lane: LaneID

    init(ownerId: String,
         group: Database.Group? = nil,
         groups: [Database.Group]? = nil,
         entities: [String]? = nil,
         tags: [String]? = nil,
         aggregate: Bool? = nil,
         scope: DatabaseRequestScope? = nil,
         requestID: String? = nil,
         mediaType: MediaType? = nil,
         topK: Int? = nil,
         lane: LaneID = .unscoped) {
        self.ownerId = ownerId
        self.group = group
        self.groups = groups
        self.entities = entities
        self.tags = tags
        self.aggregate = aggregate
        self.scope = scope
        self.requestID = requestID
        self.mediaType = mediaType
        self.topK = topK
        self.lane = lane
    }

    enum CodingKeys: String, CodingKey {
        case ownerId = "owner_id"
        case group
        case groups
        case entities
        case tags
        case aggregate
        case scope
        case requestID = "request_id"
        case mediaType = "media_type"
        case topK = "top_k"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ownerId   = try c.decode(String.self,                    forKey: .ownerId)
        group     = try c.decodeIfPresent(Database.Group.self,       forKey: .group)
        groups    = try c.decodeIfPresent([Database.Group].self,     forKey: .groups)
        entities  = try c.decodeIfPresent([String].self,         forKey: .entities)
        tags      = try c.decodeIfPresent([String].self,         forKey: .tags)
        aggregate = try c.decodeIfPresent(Bool.self,             forKey: .aggregate)
        scope     = try c.decodeIfPresent(DatabaseRequestScope.self, forKey: .scope)
        requestID = try c.decodeIfPresent(String.self,           forKey: .requestID)
        mediaType = try c.decodeIfPresent(String.self,           forKey: .mediaType).map(MediaType.init(wire:))
        topK      = try c.decodeIfPresent(Int.self,              forKey: .topK)
        lane      = .unscoped   // never from a body: the server derives it from the caller
    }

    /// In Thread there is no auth middleware — ownerId comes directly from the body.
    /// Call this with the Hummingbird request context's id: `withRequestID(context.id)`
    func withRequestID(_ id: String) -> DatabaseRequest {
        return .init(
            ownerId: self.ownerId.lowercased(),
            group: self.group,
            groups: self.groups,
            entities: self.entities,
            tags: self.tags,
            aggregate: self.aggregate,
            scope: self.scope,
            requestID: id,
            mediaType: self.mediaType,
            topK: self.topK,
            lane: self.lane
        )
    }

    /// The same request, scoped to `lane` (the route's caller, resolved from its secret).
    func scoped(to lane: LaneID) -> DatabaseRequest {
        .init(ownerId: ownerId, group: group, groups: groups, entities: entities, tags: tags,
              aggregate: aggregate, scope: scope, requestID: requestID, mediaType: mediaType,
              topK: topK, lane: lane)
    }

    /// The same request with another group (the batch route merges tags into it).
    func replacingGroup(_ group: Database.Group?) -> DatabaseRequest {
        .init(ownerId: ownerId, group: group, groups: groups, entities: entities, tags: tags,
              aggregate: aggregate, scope: scope, requestID: requestID, mediaType: mediaType,
              topK: topK, lane: lane)
    }

    /// The same request for another owner (the node's own owner when a body named none).
    func replacingOwner(_ ownerId: String) -> DatabaseRequest {
        .init(ownerId: ownerId, group: group, groups: groups, entities: entities, tags: tags,
              aggregate: aggregate, scope: scope, requestID: requestID, mediaType: mediaType,
              topK: topK, lane: lane)
    }

    /// The code instrument: identifiers matched exactly, applied as a boost.
    var isCode: Bool { mediaType == .code }

    /// `topK` as a limit, or nil for no limit.
    var resultLimit: Int? { (topK ?? 0) > 0 ? topK : nil }
}

enum DatabaseRequestScope: String, Codable {
    case global
    case personal
}
