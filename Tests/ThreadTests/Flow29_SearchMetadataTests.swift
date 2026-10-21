//
//  Flow29_SearchMetadataTests.swift
//  ThreadTests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  A search can carry each hit's document header back: its name, the group its owner
//  filed it under, and its metadata byte for byte — what a record-shaped client
//  (AIIInstance.recall) decodes a hit into. Asked for, never by default, and the same on
//  the direct port and the Session stream. Driven through the gRPC impls with the
//  shared-stack resolver, as Flow28 is.
//

import AII
import GRPCCore
import Seam
import XCTest
@testable import Thread

final class Flow29_SearchMetadataTests: XCTestCase {
    private var tempRoot: URL!
    private let owner = "local-notes"

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("thread-search-metadata-\(UUID().uuidString)")
        FilePersistence.configure(dataDirectory: tempRoot.path)
    }

    override func tearDown() {
        FilePersistence.configure(dataDirectory: nil)
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    private struct Stack {
        let database: Database
        let query: ThreadQueryServiceImpl
    }

    private func makeStack() async -> Stack {
        let database = Database(nodeId: UUID(uuidString: "00000000-0000-0000-0000-0000000029a1")!)
        await database.initializationTask.value
        return Stack(database: database,
                     query: ThreadQueryServiceImpl(database: database, embeddingProvider: MockEmbeddingProvider(),
                                                   graphExtractor: KeywordGraphExtractionProvider(), resolver: .test))
    }

    /// Craft's lane is `.b` (Fixtures).
    private let craft = LaneCaller.metadata(.presenting("craft-secret"))

    /// Bytes a JSON encoder would never write as given: the header returns them unchanged.
    private let metadata = Data(#"{"format":"aii-record/1","z":1,  "a":"spaced"}"#.utf8)

    private func indexNote(_ stack: Stack) async throws {
        var item = Thread_V1_ThreadIndexItem()
        item.documentID = "notes/note/standup"
        item.name = "Stand-up, 15 October"
        item.texts = ["Ada leads Joltvault; the stand-up moved to ten."]
        item.metadata = metadata
        var entity = Thread_V1_ThreadGraphEntityIn()
        entity.name = "Joltvault"
        entity.kind = "project"
        item.entities = [entity]
        var request = Thread_V1_ThreadIndexRequest()
        request.ownerID = owner
        request.groupID = "notes-standups"
        request.groupLabel = "Stand-ups"
        request.items = [item]
        _ = try await stack.query.index(request, caller: craft)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, stack.database.table?.keys.contains("notes/note/standup") != true {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func search(_ stack: Stack, includeMetadata: Bool, as caller: LaneCaller) async throws -> [Thread_V1_ThreadPartitionResult] {
        var request = Thread_V1_ThreadSearchRequest()
        request.ownerID = owner
        request.queryText = "who leads Joltvault?"
        request.scope = "personal"
        request.aggregate = true
        request.includeMetadata = includeMetadata
        return try await stack.query.search(request, caller: caller).results
    }

    func testAskedForTheHeaderComesBackByteForByte() async throws {
        let stack = await makeStack()
        try await indexNote(stack)
        let hits = try await search(stack, includeMetadata: true, as: craft)
        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(hit.documentID, "notes/note/standup")
        XCTAssertEqual(hit.name, "Stand-up, 15 October")
        XCTAssertEqual(hit.groupID, "notes-standups")
        XCTAssertEqual(hit.metadata, metadata)
        await stack.database.shutdown()
    }

    func testNotAskedForTheHeaderStaysEmpty() async throws {
        let stack = await makeStack()
        try await indexNote(stack)
        let hits = try await search(stack, includeMetadata: false, as: craft)
        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(hit.documentID, "notes/note/standup")
        XCTAssertTrue(hit.name.isEmpty)
        XCTAssertTrue(hit.groupID.isEmpty)
        XCTAssertTrue(hit.metadata.isEmpty)
        await stack.database.shutdown()
    }

    /// Sewn forwards the request as it came: the flag works on the Session stream too.
    func testTheSessionPathCarriesIt() async throws {
        let stack = await makeStack()
        try await indexNote(stack)
        let hits = try await search(stack, includeMetadata: true, as: .trusted(lane: LaneID.b.rawValue))
        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(hit.groupID, "notes-standups")
        XCTAssertEqual(hit.metadata, metadata)
        await stack.database.shutdown()
    }
}
