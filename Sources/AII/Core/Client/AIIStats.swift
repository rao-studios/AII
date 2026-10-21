//
//  AIIStats.swift
//  AII
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: What an app shows about its lane of the index, and what the stack
//        identity sees of every lane: Thread's `GET /v1/stats`.
//  PIN:  A client never names a lane; Thread answers for the lane of the secret
//        that called. `lanes` is filled only for the stack identity.
//

import Foundation

public struct AIIStats: Sendable, Equatable, Codable {

    public struct LaneStats: Sendable, Equatable, Codable {
        public var lane: LaneID
        public var documents: Int
        public var groups: Int
        public var owners: Int
        public var entities: Int
        public var relationships: Int

        public init(lane: LaneID, documents: Int, groups: Int, owners: Int, entities: Int, relationships: Int) {
            self.lane = lane
            self.documents = documents
            self.groups = groups
            self.owners = owners
            self.entities = entities
            self.relationships = relationships
        }
    }

    public struct TopEntity: Sendable, Equatable, Codable {
        public var id: String
        public var name: String
        public var kind: String
        public var mentionCount: Int

        enum CodingKeys: String, CodingKey {
            case id, name, kind
            case mentionCount = "mention_count"
        }

        public init(id: String, name: String, kind: String, mentionCount: Int) {
            self.id = id
            self.name = name
            self.kind = kind
            self.mentionCount = mentionCount
        }
    }

    /// The caller's lane.
    public var lane: LaneID
    public var documents: Int
    public var groups: Int
    public var owners: Int
    public var entities: Int
    public var relationships: Int
    public var topEntities: [TopEntity]
    /// Every lane's counts — the stack identity only.
    public var lanes: [LaneStats]?

    enum CodingKeys: String, CodingKey {
        case lane, documents, groups, owners, entities, relationships, lanes
        case topEntities = "top_entities"
    }

    public init(lane: LaneID, documents: Int, groups: Int, owners: Int, entities: Int, relationships: Int,
                topEntities: [TopEntity] = [], lanes: [LaneStats]? = nil) {
        self.lane = lane
        self.documents = documents
        self.groups = groups
        self.owners = owners
        self.entities = entities
        self.relationships = relationships
        self.topEntities = topEntities
        self.lanes = lanes
    }

    public static let empty = AIIStats(lane: .unscoped, documents: 0, groups: 0, owners: 0, entities: 0, relationships: 0)
}

/// One base model as Sewn reports it: on this Mac or not, and what the master
/// list says about it.
public struct AIIModelState: Sendable, Equatable {
    public enum Disk: Sendable, Equatable {
        case absent
        case downloading(Double?)
        case installed
        case failed(String?)
        /// A state this build doesn't know.
        case unknown(String)
    }

    public var id: String
    public var disk: Disk
    /// The master-list entry, when the id is on it.
    public var entry: AIIModels.Entry?

    public init(id: String, disk: Disk, entry: AIIModels.Entry?) {
        self.id = id
        self.disk = disk
        self.entry = entry
    }

    public var isInstalled: Bool { disk == .installed }
}

/// One Thread node as Sewn lists it (`GET /v1/threads`).
public struct AIIThreadNode: Sendable, Equatable, Codable {
    public var threadId: String
    public var host: String
    public var grpcPort: Int
    public var httpPort: Int
    public var lastSeen: Date
    public var isActive: Bool
    public var acceptingStorage: Bool
    /// The identity the node registered as: `aii` for the one Thread.
    public var app: String?

    enum CodingKeys: String, CodingKey {
        case threadId = "thread_id"
        case host
        case grpcPort = "grpc_port"
        case httpPort = "http_port"
        case lastSeen = "last_seen"
        case isActive = "is_active"
        case acceptingStorage = "accepting_storage"
        case app
    }
}
