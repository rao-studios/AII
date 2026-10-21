//
//  Flow28_RemoveGroupsTests.swift
//  ThreadTests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  A group exists while it holds documents. RemoveGroups deletes one outright —
//  what is filed in it, then the group, also an empty one — for the caller whose
//  own secret names the lane: it is served on the direct port only, never on the
//  Session stream, so no group delete is fanned out. Removing a group's last
//  document by id drops the group too. Driven through the gRPC impls with the
//  shared-stack resolver, as LaneIsolationTests is.
//

import AII
import GRPCCore
import Seam
import XCTest
@testable import Thread

final class Flow28_RemoveGroupsTests: XCTestCase {
    private var tempRoot: URL!
    private let owner = "one-account"
    private let ctx = GRPCCore.ServerContext(
        descriptor: .init(service: .init(fullyQualifiedService: "test"), method: "test"),
        remotePeer: "test", localPeer: "local", cancellation: .init()
    )

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("thread-remove-groups-\(UUID().uuidString)")
        FilePersistence.configure(dataDirectory: tempRoot.path)
    }

    override func tearDown() {
        FilePersistence.configure(dataDirectory: nil)
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    // MARK: - Stack

    private struct Stack {
        let database: Database
        let query: ThreadQueryServiceImpl
        let library: ThreadLibraryServiceImpl
        let update: ThreadUpdateServiceImpl
    }

    private func makeStack() async -> Stack {
        let database = Database(nodeId: UUID(uuidString: "00000000-0000-0000-0000-0000000028a1")!)
        await database.initializationTask.value
        let resolver = LaneResolver.test
        return Stack(
            database: database,
            query: ThreadQueryServiceImpl(database: database, embeddingProvider: MockEmbeddingProvider(),
                                          graphExtractor: KeywordGraphExtractionProvider(), resolver: resolver),
            library: ThreadLibraryServiceImpl(database: database, resolver: resolver),
            update: ThreadUpdateServiceImpl(database: database, resolver: resolver))
    }

    /// Ambient's lane is `.a`, Craft's `.b` (Fixtures).
    private let ambient = LaneCaller.metadata(.presenting("ambient-secret"))
    private let craft = LaneCaller.metadata(.presenting("craft-secret"))

    private func index(_ stack: Stack, id: String, group: String, as caller: LaneCaller) async throws {
        var item = Thread_V1_ThreadIndexItem()
        item.documentID = id
        item.texts = ["\(id) in \(group)"]
        var request = Thread_V1_ThreadIndexRequest()
        request.ownerID = owner
        request.groupID = group
        request.groupLabel = group
        request.items = [item]
        _ = try await stack.query.index(request, caller: caller)
        await waitUntil({ stack.database.table?.keys.contains(id) == true }, "\(id) was not indexed")
    }

    private func waitUntil(_ condition: @escaping @Sendable () -> Bool, timeout: TimeInterval = 10,
                           _ message: String) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail(message)
    }

    private func removeGroups(_ ids: [String]) -> Thread_V1_ThreadRemoveGroupsRequest {
        var request = Thread_V1_ThreadRemoveGroupsRequest()
        request.ownerID = owner
        request.groupIds = ids
        return request
    }

    private func libraryGroups(_ stack: Stack, as caller: LaneCaller) async throws -> Set<String> {
        var request = Thread_V1_ThreadLibraryRequest()
        request.ownerID = owner
        return Set(try await stack.library.library(request, caller: caller).groups.map(\.id))
    }

    // MARK: - RemoveGroups

    func testItDeletesTheGroupAndWhatIsFiledInIt() async throws {
        let stack = await makeStack()
        try await index(stack, id: "card-1", group: "craft-code-x", as: craft)
        try await index(stack, id: "card-2", group: "craft-code-x", as: craft)
        try await index(stack, id: "card-3", group: "craft-code-y", as: craft)

        let response = try await stack.update.removeGroups(removeGroups(["craft-code-x"]), caller: craft)

        XCTAssertTrue(response.success)
        XCTAssertEqual(response.removedGroupIds, ["craft-code-x"])
        XCTAssertEqual(response.removedDocumentCount, 2)
        XCTAssertEqual(stack.database.table?.keys, ["card-3"], "the table lost the group's documents, and only those")
        XCTAssertNil(stack.database.registry?.groupOwners["craft-code-x"])
        let listed = try await libraryGroups(stack, as: craft)
        XCTAssertEqual(listed, ["craft-code-y"])
        await stack.database.shutdown()
    }

    /// Queued behind the writes before it: a put into the group lands first, and goes with it.
    func testItWaitsForAPutQueuedIntoTheGroup() async throws {
        let stack = await makeStack()
        try await index(stack, id: "card-1", group: "craft-code-x", as: craft)
        let late = Database.BatchPutItem(
            id: "card-late",
            data: [EmbeddingData(embedding: .floats(VectorFixtures.random(seed: 28_001)), index: 0)],
            texts: ["filed just before the delete"])
        let group = Database.Group.test(id: "craft-code-x", ownerId: owner)
        await stack.database.enqueuePut([late], request: DatabaseRequest(ownerId: owner, group: group, aggregate: nil,
                                                                         scope: .personal, requestID: nil, lane: .b))

        let response = try await stack.update.removeGroups(removeGroups(["craft-code-x"]), caller: craft)

        XCTAssertEqual(response.removedDocumentCount, 2, "the queued put landed before the delete ran")
        XCTAssertEqual(stack.database.table?.keys.isEmpty, true)
        XCTAssertNil(stack.database.registry?.groupOwners["craft-code-x"])
        await stack.database.shutdown()
    }

    func testAnotherLanesSecretCannotDeleteTheGroup() async throws {
        let stack = await makeStack()
        try await index(stack, id: "ambient-1", group: "ambient-reading", as: ambient)

        let response = try await stack.update.removeGroups(removeGroups(["ambient-reading"]), caller: craft)

        XCTAssertEqual(response.removedGroupIds, [], "Craft's secret names Craft's lane, not Ambient's")
        XCTAssertEqual(response.removedDocumentCount, 0)
        XCTAssertEqual(stack.database.table?.keys, ["ambient-1"])
        let listed = try await libraryGroups(stack, as: ambient)
        XCTAssertEqual(listed, ["ambient-reading"])
        await stack.database.shutdown()
    }

    func testTheStackIdentityAndAnUnknownSecretAreRefused() async throws {
        let stack = await makeStack()
        try await index(stack, id: "card-1", group: "craft-code-x", as: craft)
        do {
            _ = try await stack.update.removeGroups(removeGroups(["craft-code-x"]), caller: .metadata(.presenting("aii-secret")))
            XCTFail("the stack identity has no lane to delete from")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .failedPrecondition)
        }
        do {
            _ = try await stack.update.removeGroups(removeGroups(["craft-code-x"]), caller: .metadata(.presenting("stranger")))
            XCTFail("an unknown secret has no lane")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .unauthenticated)
        }
        XCTAssertNotNil(stack.database.registry?.groupOwners["craft-code-x"])
        await stack.database.shutdown()
    }

    /// Direct only: a lane stamped on the caller's behalf — the Session stream's — is refused.
    func testASessionCallerIsRefused() async throws {
        let stack = await makeStack()
        try await index(stack, id: "card-1", group: "craft-code-x", as: craft)
        do {
            _ = try await stack.update.removeGroups(removeGroups(["craft-code-x"]), caller: .trusted(lane: LaneID.b.rawValue))
            XCTFail("RemoveGroups is not served on the Session stream")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .permissionDenied)
        }
        XCTAssertNotNil(stack.database.registry?.groupOwners["craft-code-x"])
        await stack.database.shutdown()
    }

    func testAnEmptyListRemovesNothing() async throws {
        let stack = await makeStack()
        try await index(stack, id: "card-1", group: "craft-code-x", as: craft)

        let response = try await stack.update.removeGroups(removeGroups([]), caller: craft)

        XCTAssertTrue(response.success)
        XCTAssertEqual(response.removedGroupIds, [])
        XCTAssertEqual(stack.database.table?.keys, ["card-1"], "never everything, as an empty Remove is")
        await stack.database.shutdown()
    }

    /// Registered on the direct port through this conformance — the one that sees the
    /// request's metadata, where the caller's secret (and so its lane) rides.
    func testTheDirectPortServesIt() async throws {
        let stack = await makeStack()
        try await index(stack, id: "card-1", group: "craft-code-x", as: craft)
        let update: any Thread_V1_ThreadUpdate.ServiceProtocol = stack.update

        let response = try await update.removeGroups(
            request: ServerRequest(metadata: .presenting("craft-secret"), message: removeGroups(["craft-code-x"])), context: ctx).message

        XCTAssertEqual(response.removedGroupIds, ["craft-code-x"])
        XCTAssertEqual(stack.database.table?.keys.isEmpty, true)
        await stack.database.shutdown()
    }

    // MARK: - The last document out takes the group

    func testRemovingAGroupsLastDocumentByIdDropsTheGroup() async throws {
        let stack = await makeStack()
        try await index(stack, id: "card-1", group: "craft-code-x", as: craft)
        try await index(stack, id: "card-2", group: "craft-code-y", as: craft)

        var remove = Thread_V1_ThreadRemoveRequest()
        remove.ownerID = owner
        remove.documentIds = ["card-1"]
        _ = try await stack.query.remove(remove, caller: craft)
        await waitUntil({ stack.database.table?.keys.contains("card-1") == false }, "card-1 was not removed")

        XCTAssertNil(stack.database.registry?.groupOwners["craft-code-x"], "the emptied group went with its last document")
        let listed = try await libraryGroups(stack, as: craft)
        XCTAssertEqual(listed, ["craft-code-y"])
        await stack.database.shutdown()
    }
}
