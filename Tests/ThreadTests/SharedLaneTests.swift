//
//  SharedLaneTests.swift
//  ThreadTests
//
//  Created by Ritesh Pakala on 11/05/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  Link is a shared lane: every lane reads it, only Link's credential writes it. An
//  app's search, documents and library see a linked device's notes beside its own; its
//  removals and its wipe never reach them.
//

import AII
import GRPCCore
import Seam
import XCTest
@testable import Thread

final class SharedLaneTests: XCTestCase {
    private var tempRoot: URL!
    private let owner = "one-account"
    private static let linkLane = LaneID(rawValue: "dddddddd-0000-4000-8000-00000000000d")

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("thread-shared-\(UUID().uuidString)")
        FilePersistence.configure(dataDirectory: tempRoot.path)
        ThreadSharedLanes.set([Self.linkLane])
    }

    override func tearDown() {
        ThreadSharedLanes.set([])
        FilePersistence.configure(dataDirectory: nil)
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    private let ambient = LaneCaller.metadata(.presenting("ambient-secret"))
    private let craft = LaneCaller.metadata(.presenting("craft-secret"))
    private let link = LaneCaller.metadata(.presenting("link-secret"))

    private static let resolver: LaneResolver = {
        var lanes = AIILanes.test.lanes
        lanes[.link] = .fixed(linkLane, for: .link)
        let ring = StackKeyring(fixed: [
            .app(.ambient): "ambient-secret", .app(.craft): "craft-secret", .app(.link): "link-secret", .stack: "aii-secret",
        ])
        return LaneResolver(stack: .multiApp(ring), lanes: AIILaneRegistry(fixed: AIILanes(lanes: lanes)))
    }()

    private struct Stack {
        let database: Database
        let query: ThreadQueryServiceImpl
        let library: ThreadLibraryServiceImpl
    }

    private func makeStack() async -> Stack {
        let database = Database(nodeId: UUID(uuidString: "00000000-0000-0000-0000-0000000011e0")!)
        await database.initializationTask.value
        let provider = MockEmbeddingProvider()
        return Stack(
            database: database,
            query: ThreadQueryServiceImpl(database: database, embeddingProvider: provider,
                                          graphExtractor: KeywordGraphExtractionProvider(), resolver: Self.resolver),
            library: ThreadLibraryServiceImpl(database: database, resolver: Self.resolver))
    }

    private func index(_ stack: Stack, id: String, text: String, group: String, entity: String,
                       as caller: LaneCaller) async throws {
        var item = Thread_V1_ThreadIndexItem()
        item.documentID = id
        item.texts = [text]
        var e = Thread_V1_ThreadGraphEntityIn()
        e.name = entity
        e.kind = "concept"
        item.entities = [e]
        var request = Thread_V1_ThreadIndexRequest()
        request.ownerID = owner
        request.groupID = group
        request.groupLabel = group
        request.items = [item]
        _ = try await stack.query.index(request, caller: caller)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, stack.database.table?.keys.contains(id) != true {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(stack.database.table?.keys.contains(id), true, "\(id) was indexed")
    }

    private func fill(_ stack: Stack) async throws {
        try await index(stack, id: "ambient/reading/1", text: "Ambient read about tide pools.", group: "ambient-reading-x",
                        entity: "Tide Pools", as: ambient)
        try await index(stack, id: "craft/lesson/1", text: "Craft learned about tide pools in tests.", group: "craft-records",
                        entity: "Tide Pools", as: craft)
        try await index(stack, id: "link/note/1", text: "A note from the phone about tide pools.", group: "link-x",
                        entity: "Tide Pools", as: link)
    }

    private func search(_ stack: Stack, as caller: LaneCaller) async throws -> Set<String> {
        var request = Thread_V1_ThreadSearchRequest()
        request.ownerID = owner
        request.queryText = "tide pools"
        request.scope = "personal"
        request.aggregate = true
        return Set(try await stack.query.search(request, caller: caller).results.map(\.documentID))
    }

    private func documents(_ stack: Stack, as caller: LaneCaller) async throws -> Set<String> {
        var request = Thread_V1_ThreadDocumentsRequest()
        request.ownerID = owner
        request.documentIds = ["ambient/reading/1", "craft/lesson/1", "link/note/1"]
        return Set(try await stack.library.documents(request, caller: caller).documents.map(\.id))
    }

    private func groups(_ stack: Stack, as caller: LaneCaller) async throws -> Set<String> {
        var request = Thread_V1_ThreadLibraryRequest()
        request.ownerID = owner
        return Set(try await stack.library.library(request, caller: caller).groups.map(\.id))
    }

    func testEveryLaneReadsLinkBesideItsOwn() async throws {
        let stack = await makeStack()
        try await fill(stack)

        let ambientHits = try await search(stack, as: ambient)
        XCTAssertEqual(ambientHits, ["ambient/reading/1", "link/note/1"])
        let craftHits = try await search(stack, as: craft)
        XCTAssertEqual(craftHits, ["craft/lesson/1", "link/note/1"])
        let linkHits = try await search(stack, as: link)
        XCTAssertEqual(linkHits, ["link/note/1"], "Link reads only its own")

        let ambientDocuments = try await documents(stack, as: ambient)
        XCTAssertEqual(ambientDocuments, ["ambient/reading/1", "link/note/1"])
        let ambientGroups = try await groups(stack, as: ambient)
        XCTAssertEqual(ambientGroups, ["ambient-reading-x", "link-x"])
        await stack.database.shutdown()
    }

    func testNoOtherLaneRemovesWhatLinkFiled() async throws {
        let stack = await makeStack()
        try await fill(stack)

        var remove = Thread_V1_ThreadRemoveRequest()
        remove.ownerID = owner
        remove.documentIds = ["link/note/1"]
        _ = try await stack.query.remove(remove, caller: ambient)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(stack.database.table?.keys.contains("link/note/1"), true, "a reader is not a remover")

        // Ambient's wipe of everything it holds leaves the note.
        remove.documentIds = []
        _ = try await stack.query.remove(remove, caller: ambient)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(stack.database.table?.keys.contains("ambient/reading/1"), false)
        XCTAssertEqual(stack.database.table?.keys.contains("link/note/1"), true)

        // A lane clear is the lane's own.
        _ = await stack.database.clear(lane: .a)
        XCTAssertEqual(stack.database.table?.keys.contains("link/note/1"), true)

        remove.documentIds = ["link/note/1"]
        _ = try await stack.query.remove(remove, caller: link)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, stack.database.table?.keys.contains("link/note/1") == true {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(stack.database.table?.keys.contains("link/note/1"), false, "Link removes its own")
        await stack.database.shutdown()
    }

    func testWithoutSharedLanesEveryLaneIsItsOwn() async throws {
        ThreadSharedLanes.set([])
        let stack = await makeStack()
        try await fill(stack)
        let ambientHits = try await search(stack, as: ambient)
        XCTAssertEqual(ambientHits, ["ambient/reading/1"])
        await stack.database.shutdown()
    }
}
