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

    /// An owner's public (`available`) group is read from every lane: an AII another app connects to answers with what
    /// its owner published. Only the filing lane publishes or removes it, and a document filed into it later is public.
    func testAPublicGroupIsReadFromEveryLane() async throws {
        ThreadSharedLanes.set([])
        let stack = await makeStack()
        try await fill(stack)
        let ambientLane = try Self.resolver.writeLane(try Self.resolver.scope(for: ambient))
        let craftLane = try Self.resolver.writeLane(try Self.resolver.scope(for: craft))

        let refused = await stack.database.updateGroupAccess("ambient-reading-x", ownerId: owner, access: .available, lane: craftLane)
        XCTAssertFalse(refused, "a reader does not publish another lane's group")
        let craftBefore = try await search(stack, as: craft)
        XCTAssertEqual(craftBefore, ["craft/lesson/1"])

        let published = await stack.database.updateGroupAccess("ambient-reading-x", ownerId: owner, access: .available, lane: ambientLane)
        XCTAssertTrue(published)
        try await index(stack, id: "ambient/reading/2", text: "Ambient read more about tide pools.", group: "ambient-reading-x",
                        entity: "Tide Pools", as: ambient)
        let craftAfter = try await search(stack, as: craft)
        XCTAssertEqual(craftAfter, ["craft/lesson/1", "ambient/reading/1", "ambient/reading/2"])
        let craftDocuments = try await documents(stack, as: craft)
        XCTAssertEqual(craftDocuments, ["craft/lesson/1", "ambient/reading/1"])
        let linkHits = try await search(stack, as: link)
        XCTAssertFalse(linkHits.contains("craft/lesson/1"), "a restricted group stays its lane's")

        var remove = Thread_V1_ThreadRemoveRequest()
        remove.ownerID = owner
        remove.documentIds = ["ambient/reading/1"]
        _ = try await stack.query.remove(remove, caller: craft)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(stack.database.table?.keys.contains("ambient/reading/1"), true, "a reader is not a remover")

        _ = await stack.database.updateGroupAccess("ambient-reading-x", ownerId: owner, access: .restricted, lane: ambientLane)
        let craftWithdrawn = try await search(stack, as: craft)
        XCTAssertEqual(craftWithdrawn, ["craft/lesson/1"], "withdrawn is the lane's own again")
        await stack.database.shutdown()
    }

    /// The HTTP search (`/v1/search`) is what an app that connected an AII by its address asks: from another lane, with
    /// any owner, global scope reaches what the AII's owner published, and every partition comes back with its score.
    func testTheTextSearchReachesPublicDocumentsWithAScoreEach() async throws {
        ThreadSharedLanes.set([])
        let stack = await makeStack()
        try await fill(stack)
        let ambientLane = try Self.resolver.writeLane(try Self.resolver.scope(for: ambient))
        let craftLane = try Self.resolver.writeLane(try Self.resolver.scope(for: craft))
        _ = await stack.database.updateGroupAccess("ambient-reading-x", ownerId: owner, access: .available, lane: ambientLane)

        let request = DatabaseRequest(ownerId: "someone-else", scope: .global, topK: 10).scoped(to: craftLane)
        let result = try await stack.database.search("tide pools", request: request, embeddingModelProvider: MockEmbeddingProvider())
        XCTAssertEqual(Set(result.partitions.map(\.documentId)), ["ambient/reading/1"], "public, and nothing restricted of another lane")
        XCTAssertEqual(result.scores.count, result.partitions.count)

        let keyless = DatabaseRequest(ownerId: "anyone", scope: .global, topK: 10).scoped(to: .publicAccess)
        let open = try await stack.database.search("tide pools", request: keyless, embeddingModelProvider: MockEmbeddingProvider())
        XCTAssertEqual(Set(open.partitions.map(\.documentId)), ["ambient/reading/1"], "a caller with no key reads what is public")
        let registry = try XCTUnwrap(stack.database.registry)
        XCTAssertEqual(registry.documents(visibleFrom: .publicAccess), registry.availableDocumentIds, "public only, no lane's own")
        XCTAssertNil(LaneScope.lane(.publicAccess).writeLane, "and it writes nothing")
        await stack.database.shutdown()
    }

    /// Access is set on the group and every document filed into it inherits it, now and later; one document can still be
    /// restricted inside a public group: a caller with no key gets the rest, its owner's key gets them all.
    func testARestrictedDocumentInAPublicGroupIsLeftOutWithoutAKey() async throws {
        ThreadSharedLanes.set([])
        let stack = await makeStack()
        try await fill(stack)
        let ambientLane = try Self.resolver.writeLane(try Self.resolver.scope(for: ambient))
        _ = await stack.database.updateGroupAccess("ambient-reading-x", ownerId: owner, access: .available, lane: ambientLane)
        try await index(stack, id: "ambient/reading/2", text: "Ambient's private notes on tide pools.", group: "ambient-reading-x",
                        entity: "Tide Pools", as: ambient)
        try await index(stack, id: "ambient/reading/3", text: "Ambient's open notes on tide pools.", group: "ambient-reading-x",
                        entity: "Tide Pools", as: ambient)
        let restricted = await stack.database.updateDocumentAccess("ambient/reading/2", ownerId: owner, access: .restricted, lane: ambientLane)
        XCTAssertTrue(restricted)

        func found(_ lane: LaneID) async throws -> Set<String> {
            let request = DatabaseRequest(ownerId: owner, scope: .global, topK: 10).scoped(to: lane)
            let result = try await stack.database.search("tide pools", request: request, embeddingModelProvider: MockEmbeddingProvider())
            return Set(result.partitions.map(\.documentId))
        }
        let keyless = try await found(.publicAccess)
        XCTAssertEqual(keyless, ["ambient/reading/1", "ambient/reading/3"], "filed later, inherited; one restricted, left out")
        let keyed = try await found(ambientLane)
        XCTAssertEqual(keyed, ["ambient/reading/1", "ambient/reading/2", "ambient/reading/3"], "the owner's key reads them all")
        await stack.database.shutdown()
    }

    /// A caller with no key never reads a shared lane (Link): shared is between the stack's apps, not public.
    func testAPublicReaderDoesNotReadTheSharedLanes() async throws {
        let stack = await makeStack()
        try await fill(stack)
        let linkLane = try Self.resolver.writeLane(try Self.resolver.scope(for: link))
        let registry = try XCTUnwrap(stack.database.registry)
        let visible = try XCTUnwrap(registry.documents(visibleFrom: .publicAccess, shared: [linkLane]))
        XCTAssertTrue(visible.isEmpty, "Link's note is shared between the stack's apps, not public: \(visible)")
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
