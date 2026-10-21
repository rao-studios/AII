//
//  Fixtures.swift
//  ThreadTests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//

import AII
import Foundation
import GRPCCore
import Logging
import Seam
@testable import Thread

// MARK: - Persistence cleanup

func wipeThreadPersistenceFiles() {
    let db = FilePersistence.getDefaultURL()
    for key in ["table", "registry"] {
        try? FileManager.default.removeItem(at: db.appendingPathComponent(key))
    }
    if let contents = try? FileManager.default.contentsOfDirectory(
        at: db, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
    ) {
        for url in contents where url.lastPathComponent.hasPrefix("shard-")
            || url.lastPathComponent.hasPrefix("table-")
            || url.lastPathComponent.hasPrefix("graph-") {
            try? FileManager.default.removeItem(at: url)
        }
    }
    try? FileManager.default.removeItem(at: db.appendingPathComponent("personal"))
}

// MARK: - Logger

extension Logger {
    static var test: Logger {
        var logger = Logger(label: "test-thread")
        logger.logLevel = .critical
        return logger
    }
}

extension ThreadLogger {
    static var test: ThreadLogger { ThreadLogger(.test) }
}

// MARK: - DatabaseRequest

extension DatabaseRequest {
    static func test(
        ownerId: String = "test-owner",
        scope: DatabaseRequestScope? = .personal,
        mediaType: MediaType? = nil,
        topK: Int? = nil,
        lane: LaneID = .unscoped
    ) -> DatabaseRequest {
        DatabaseRequest(ownerId: ownerId, group: nil, aggregate: nil, scope: scope, requestID: nil,
                        mediaType: mediaType, topK: topK, lane: lane)
    }
}

// MARK: - Lanes

extension LaneID {
    /// Two fixed lanes for tests that split an index.
    static let a = LaneID(rawValue: "aaaaaaaa-0000-4000-8000-00000000000a")
    static let b = LaneID(rawValue: "bbbbbbbb-0000-4000-8000-00000000000b")
}

extension AIILanes {
    /// Ambient → `.a`, Craft → `.b`, Veil → a third fixed id.
    static let test = AIILanes(lanes: [
        .ambient: .fixed(.a, for: .ambient),
        .craft: .fixed(.b, for: .craft),
        .veil: .fixed(LaneID(rawValue: "cccccccc-0000-4000-8000-00000000000c"), for: .veil),
    ])
}

extension AIILanes.Lane {
    /// A manifest entry with a fixed id, registered by the app, under its default owner.
    static func fixed(_ id: LaneID, for app: AIIApp) -> AIILanes.Lane {
        AIILanes.Lane(id: id, derivedFrom: "test", registeredAt: Date(timeIntervalSince1970: 0), displayName: app.displayName,
                      registeredBy: .app(app), owner: AIILanes.defaultOwner(for: app))
    }
}

extension StackKeyring {
    /// Fixed secrets per identity for a shared-stack Thread under test.
    static let test = StackKeyring(fixed: [
        .app(.ambient): "ambient-secret", .app(.craft): "craft-secret", .app(.veil): "veil-secret", .stack: "aii-secret",
    ])
}

extension LaneResolver {
    /// A shared-stack resolver with the fixed keyring and lanes.
    static let test = LaneResolver(stack: .multiApp(.test), lanes: AIILaneRegistry(fixed: .test))
}

extension Metadata {
    /// Request metadata presenting `secret` the way a direct gRPC client does.
    static func presenting(_ secret: String) -> Metadata {
        var metadata = Metadata()
        metadata.addString(secret, forKey: StackSecret.metadataKey)
        return metadata
    }
}

// MARK: - The impls' old call shape

/// The impls take `(message, caller:)`; these keep the tests that drove them through
/// the one-app shape — a message and a dummy ServerContext — reading as they did,
/// as an unscoped caller.
extension ThreadQueryServiceImpl {
    func search(request: Thread_V1_ThreadSearchRequest, context: ServerContext) async throws -> Thread_V1_ThreadSearchResponse {
        try await search(request, caller: .scope(.lane(.unscoped)))
    }
    func index(request: Thread_V1_ThreadIndexRequest, context: ServerContext) async throws -> Thread_V1_ThreadIndexResponse {
        try await index(request, caller: .scope(.lane(.unscoped)))
    }
    func remove(request: Thread_V1_ThreadRemoveRequest, context: ServerContext) async throws -> Thread_V1_ThreadRemoveResponse {
        try await remove(request, caller: .scope(.lane(.unscoped)))
    }
}

extension ThreadLibraryServiceImpl {
    func library(request: Thread_V1_ThreadLibraryRequest, context: ServerContext) async throws -> Thread_V1_ThreadLibraryResponse {
        try await library(request, caller: .scope(.lane(.unscoped)))
    }
    func documents(request: Thread_V1_ThreadDocumentsRequest, context: ServerContext) async throws -> Thread_V1_ThreadDocumentsResponse {
        try await documents(request, caller: .scope(.lane(.unscoped)))
    }
    func exportCorpus(request: Thread_V1_ThreadExportCorpusRequest, context: ServerContext) async throws -> Thread_V1_ThreadExportCorpusResponse {
        try await exportCorpus(request, caller: .scope(.lane(.unscoped)))
    }
}

extension ThreadGraphServiceImpl {
    func query(request: Thread_V1_ThreadGraphQueryRequest, context: ServerContext) async throws -> Thread_V1_ThreadGraphQueryResponse {
        try await query(request, caller: .scope(.lane(.unscoped)))
    }
}

extension ThreadUpdateServiceImpl {
    func updateGroup(request: Thread_V1_ThreadUpdateGroupRequest, context: ServerContext) async throws -> Thread_V1_ThreadUpdateGroupResponse {
        try await updateGroup(request, caller: .scope(.lane(.unscoped)))
    }
    func updateDocument(request: Thread_V1_ThreadUpdateDocumentRequest, context: ServerContext) async throws -> Thread_V1_ThreadUpdateDocumentResponse {
        try await updateDocument(request, caller: .scope(.lane(.unscoped)))
    }
    func stats(request: Thread_V1_ThreadStatsRequest, context: ServerContext) async throws -> Thread_V1_ThreadStatsResponse {
        try await stats(request, caller: .scope(.lane(.unscoped)))
    }
    func removeGroups(request: Thread_V1_ThreadRemoveGroupsRequest, context: ServerContext) async throws -> Thread_V1_ThreadRemoveGroupsResponse {
        try await removeGroups(request, caller: .scope(.lane(.unscoped)))
    }
}

// MARK: - Database.Partition

extension Database.Partition {
    static func test(
        id: String = UUID().uuidString,
        documentId: String = "test-doc",
        url: URL = URL(string: "https://example.com")!,
        embedding: [Float] = [],
        text: String = "test text here",
        ownerId: String = "test-owner"
    ) -> Database.Partition {
        Database.Partition(
            id: id,
            documentId: documentId,
            url: url,
            embedding: embedding,
            text: text,
            ownerId: ownerId
        )
    }
}

// MARK: - TableMutator

extension TableMutator {
    static func test() -> TableMutator {
        TableMutator(nodeId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, logger: .test)
    }
}

// MARK: - RegistryMutator

extension RegistryMutator {
    static func test() -> RegistryMutator {
        let m = RegistryMutator(
            nodeId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            logger: .test
        )
        m.seed(ThreadRegistry())
        return m
    }
}

// MARK: - Database.Document

extension Database.Document {
    static func test(
        id: String = UUID().uuidString,
        ownerId: String = "test-owner"
    ) -> Database.Document {
        Database.Document(id: id, url: URL(string: "https://example.com")!, ownerId: ownerId)
    }
}

// MARK: - Database.Group

extension Database.Group {
    static func test(
        id: String = "test-group",
        label: String = "Test Group",
        ownerId: String = "test-owner",
        metadata: Database.Group.Metadata? = nil
    ) -> Database.Group {
        Database.Group(id: id, label: label, ownerId: ownerId, documents: [], metadata: metadata)
    }
}

// MARK: - Database.Group.Metadata

extension Database.Group.Metadata {
    static func test(
        description: String? = "A test group description",
        tags: [String] = ["swift", "test"]
    ) -> Database.Group.Metadata {
        Database.Group.Metadata(description: description, tags: tags)
    }
}

// MARK: - MockEmbeddingProvider

actor MockEmbeddingProvider: EmbeddingProviding {
    private var callCount = 0

    func acquirePreprocessSlot() async {}
    func releasePreprocessSlot() async {}

    func run(
        _ texts: [String],
        logger: Logger,
        role: EmbeddingRole
    ) async throws -> (result: [EmbeddingData], usage: Requests.Embedding.Get.Result.Usage) {
        let embeddings = texts.enumerated().map { (i, _) -> EmbeddingData in
            let seed = UInt64(i + callCount * 1000 + 99000)
            return EmbeddingData(
                embedding: .floats(VectorFixtures.random(dim: VectorFixtures.embeddingDim, seed: seed)),
                index: i
            )
        }
        callCount += texts.count
        let usage = Requests.Embedding.Get.Result.Usage(
            promptAudioSeconds: nil,
            promptTokens: texts.count,
            totalTokens: texts.count,
            completionTokens: 0,
            requestCount: nil,
            promptTokenDetails: nil
        )
        return (embeddings, usage)
    }
}

// MARK: - Vector Fixtures

/// Deterministic vector helpers for reproducible test cases.
/// All vectors use `dim = 32` — divisible by 16 (PartitionQuantizer.numSubvectors).
enum VectorFixtures {
    static let dim = 32
    /// Full production embedding dimension (mistral-embed).
    static let embeddingDim = 1024

    /// All-zero vector.
    static func zeros() -> [Float] { [Float](repeating: 0, count: dim) }

    /// Unit vector along a single axis.
    static func unit(axis: Int) -> [Float] {
        var v = [Float](repeating: 0, count: dim)
        v[axis % dim] = 1.0
        return v
    }

    /// Seeded pseudo-random vector — deterministic across runs.
    static func random(seed: UInt64) -> [Float] {
        random(dim: dim, seed: seed)
    }

    /// Seeded pseudo-random vector at an explicit dimension.
    static func random(dim: Int, seed: UInt64) -> [Float] {
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        return (0..<dim).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int(bitPattern: UInt(state >> 33)) % 1000) / 500.0 - 1.0
        }
    }

    /// Vector very close to `center` (small perturbation).
    static func near(_ center: [Float], seed: UInt64) -> [Float] {
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        return center.map { c in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let noise = Float(Int(bitPattern: UInt(state >> 33)) % 100) / 100000.0
            return c + noise
        }
    }

    /// L2 distance between two vectors.
    static func l2(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).map { d in let e = d.0 - d.1; return e * e }.reduce(0, +).squareRoot()
    }
}
