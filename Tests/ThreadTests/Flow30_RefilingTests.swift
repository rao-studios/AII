//
//  Flow30_RefilingTests.swift
//  ThreadTests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  What filing an id again, and filing into groups and partitions, must leave behind:
//  - T1: re-filing replaces a document's graph links. Identical content changes no link
//    and no count; changed content drops the links it no longer asserts, and leaves the
//    edges other documents assert between the same entities alone.
//  - T2: filings of one id apply in the order Index answered them.
//  - T3: a group is its first owner's, in its first lane; naming another's is refused.
//    One owner across two lanes is fine when each app's groups carry its name.
//  - T5: a hit carries its partition's own url when the filer gave one.
//  - T6: identical vectors in one document keep distinct partitions.
//  - T7: a supplied vector of another size than the embedder's is refused.
//

import AII
import GRPCCore
import Logging
import Seam
import XCTest
@testable import Thread

/// RecordingEmbeddingProvider's vectors, in a named space of 1024 dimensions.
actor SpacedEmbeddingProvider: EmbeddingProviding {
    nonisolated var vectorSpace: String? { "test-space@\(VectorFixtures.embeddingDim)" }

    func acquirePreprocessSlot() async {}
    func releasePreprocessSlot() async {}

    func run(_ texts: [String], logger: Logger, role: EmbeddingRole)
        async throws -> (result: [EmbeddingData], usage: Requests.Embedding.Get.Result.Usage) {
        let result = texts.enumerated().map { i, text in
            EmbeddingData(embedding: .floats(RecordingEmbeddingProvider.vector(for: text)), index: i)
        }
        let usage = Requests.Embedding.Get.Result.Usage(promptAudioSeconds: nil, promptTokens: texts.count,
                                                        totalTokens: texts.count, completionTokens: 0,
                                                        requestCount: nil, promptTokenDetails: nil)
        return (result, usage)
    }
}

final class Flow30_RefilingTests: XCTestCase {
    private var tempRoot: URL!
    private let owner = "aii-local"
    private let dim = VectorFixtures.embeddingDim

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("thread-refiling-\(UUID().uuidString)")
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
    }

    /// Lanes as Fixtures registers them: Ambient's is `.a`, Craft's `.b`.
    private func makeStack(embedder: any EmbeddingProviding = RecordingEmbeddingProvider()) async -> Stack {
        let database = Database(nodeId: UUID(uuidString: "00000000-0000-0000-0000-0000000030a1")!)
        await database.initializationTask.value
        return Stack(database: database,
                     query: ThreadQueryServiceImpl(database: database, embeddingProvider: embedder,
                                                   graphExtractor: KeywordGraphExtractionProvider(), resolver: .test))
    }

    private let craft = LaneCaller.metadata(.presenting("craft-secret"))
    private let ambient = LaneCaller.metadata(.presenting("ambient-secret"))

    private func entity(_ name: String, _ kind: String) -> Thread_V1_ThreadGraphEntityIn {
        var e = Thread_V1_ThreadGraphEntityIn()
        e.name = name
        e.kind = kind
        return e
    }

    private func relation(_ subject: String, _ predicate: String, _ object: String) -> Thread_V1_ThreadGraphRelationIn {
        var r = Thread_V1_ThreadGraphRelationIn()
        r.subject = subject
        r.predicate = predicate
        r.object = object
        return r
    }

    private func item(_ id: String, text: String, entities: [Thread_V1_ThreadGraphEntityIn] = [],
                      relationships: [Thread_V1_ThreadGraphRelationIn] = []) -> Thread_V1_ThreadIndexItem {
        var item = Thread_V1_ThreadIndexItem()
        item.documentID = id
        item.texts = [text]
        item.entities = entities
        item.relationships = relationships
        return item
    }

    private func request(_ items: [Thread_V1_ThreadIndexItem], owner: String? = nil,
                         group: String = "craft-records") -> Thread_V1_ThreadIndexRequest {
        var r = Thread_V1_ThreadIndexRequest()
        r.ownerID = owner ?? self.owner
        r.groupID = group
        r.groupLabel = "Records"
        r.items = items
        return r
    }

    /// Files `items` and waits until every put has landed in the table.
    private func file(_ stack: Stack, _ request: Thread_V1_ThreadIndexRequest, as caller: LaneCaller) async throws {
        let before = stack.database.nonisolatedTableMutator.mutationVersion
        _ = try await stack.query.index(request, caller: caller)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline,
              stack.database.nonisolatedTableMutator.mutationVersion < before + UInt64(request.items.count) {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertGreaterThanOrEqual(stack.database.nonisolatedTableMutator.mutationVersion, before + UInt64(request.items.count),
                                    "the put landed")
    }

    private func entityID(_ name: String, _ kind: String) -> EntityID { GraphStore.entityID(kind: kind, name: name) }

    // MARK: - T1: re-filing replaces the graph

    func testRefilingIdenticalContentChangesNoLinkAndNoCount() async throws {
        let stack = await makeStack()
        let note = item("craft/note/a", text: "Ada leads Joltvault.",
                        entities: [entity("Ada", "person"), entity("Joltvault", "project")],
                        relationships: [relation("Ada", "leads", "Joltvault")])
        try await file(stack, request([note]), as: craft)
        let first = try XCTUnwrap(stack.database.graph)

        try await file(stack, request([note]), as: craft)
        let again = try XCTUnwrap(stack.database.graph)

        for id in [entityID("Ada", "person"), entityID("Joltvault", "project")] {
            XCTAssertEqual(again.entities[id]?.mentionCount, first.entities[id]?.mentionCount, "\(id)")
            XCTAssertEqual(again.entities[id]?.documentIds, ["craft/note/a"])
        }
        let edge = GraphStore.relationshipID(subjectId: entityID("Ada", "person"), predicate: "leads",
                                             objectId: entityID("Joltvault", "project"))
        XCTAssertEqual(again.relationships[edge]?.weight, 1)
        XCTAssertEqual(again.predicates[GraphStore.predicateID("leads")]?.relationshipCount, 1)
        await stack.database.shutdown()
    }

    func testRefilingChangedContentDropsWhatItNoLongerAssertsAndSparesOthersEdges() async throws {
        let stack = await makeStack()
        try await file(stack, request([
            item("craft/note/a", text: "Ada leads Joltvault.",
                 entities: [entity("Ada", "person"), entity("Joltvault", "project")],
                 relationships: [relation("Ada", "leads", "Joltvault")]),
            item("craft/note/b", text: "Bo uses Joltvault.",
                 entities: [entity("Bo", "person"), entity("Joltvault", "project")],
                 relationships: [relation("Bo", "uses", "Joltvault")]),
        ]), as: craft)

        try await file(stack, request([
            item("craft/note/a", text: "Ada leads Kestrel now.",
                 entities: [entity("Ada", "person"), entity("Kestrel", "project")],
                 relationships: [relation("Ada", "leads", "Kestrel")]),
        ]), as: craft)

        let graph = try XCTUnwrap(stack.database.graph)
        let joltvault = try XCTUnwrap(graph.entities[entityID("Joltvault", "project")])
        XCTAssertEqual(joltvault.documentIds, ["craft/note/b"], "the new version no longer mentions it")
        XCTAssertEqual(joltvault.mentionCount, 1)
        XCTAssertEqual(graph.entities[entityID("Kestrel", "project")]?.documentIds, ["craft/note/a"])
        let adaLeadsJoltvault = GraphStore.relationshipID(subjectId: entityID("Ada", "person"), predicate: "leads",
                                                          objectId: entityID("Joltvault", "project"))
        XCTAssertNil(graph.relationships[adaLeadsJoltvault], "the dropped assertion is gone")
        let boUsesJoltvault = GraphStore.relationshipID(subjectId: entityID("Bo", "person"), predicate: "uses",
                                                        objectId: entityID("Joltvault", "project"))
        XCTAssertEqual(graph.relationships[boUsesJoltvault]?.weight, 1, "another document's edge keeps its weight")
        XCTAssertEqual(graph.predicates[GraphStore.predicateID("leads")]?.relationshipCount, 1)
        await stack.database.shutdown()
    }

    // MARK: - T2: filings apply in Index order

    func testAnOlderFilingThatArrivesLateIsSkipped() async throws {
        let stack = await makeStack()
        let request = DatabaseRequest(ownerId: owner, group: Database.Group(id: "craft-records", label: "Records",
                                                                           ownerId: owner, documents: []),
                                      scope: .personal, lane: .unscoped)
        func filing(_ text: String, sequence: UInt64) -> Database.BatchPutItem {
            var item = Database.BatchPutItem(
                id: "craft/note/late", data: [EmbeddingData(embedding: .floats(RecordingEmbeddingProvider.vector(for: text)), index: 0)],
                texts: [text], metadata: Data(text.utf8))
            item.sequence = sequence
            return item
        }
        await stack.database.putBatch([filing("newer", sequence: 9)], request: request)
        await stack.database.putBatch([filing("older", sequence: 4)], request: request)
        XCTAssertEqual(stack.database.table?.index(for: "craft/note/late")?.metadata, Data("newer".utf8))

        await stack.database.putBatch([filing("older in a batch", sequence: 10), filing("newest", sequence: 11)],
                                      request: request)
        XCTAssertEqual(stack.database.table?.index(for: "craft/note/late")?.metadata, Data("newest".utf8))
        await stack.database.shutdown()
    }

    // MARK: - T3: groups are their first owner's, in their first lane

    func testOneOwnerInTwoLanesFilesIntoEachAppsOwnGroups() async throws {
        let stack = await makeStack()
        try await file(stack, request([item("craft/note/one", text: "Craft's note.")], group: "craft-records"), as: craft)
        try await file(stack, request([item("ambient/turn/one", text: "Ambient's turn.")], group: "ambient-interaction-aii-local"),
                       as: ambient)
        let registry = try XCTUnwrap(stack.database.registry)
        XCTAssertEqual(registry.lane(ofGroup: "craft-records"), .b)
        XCTAssertEqual(registry.lane(ofGroup: "ambient-interaction-aii-local"), .a)
        await stack.database.shutdown()
    }

    func testNamingAGroupAnotherOwnerOrLaneHoldsIsRefused() async throws {
        let stack = await makeStack()
        try await file(stack, request([item("craft/note/held", text: "Held.")], group: "craft-shared"), as: craft)

        do {
            _ = try await stack.query.index(request([item("craft/note/other", text: "Other owner.")], owner: "someone-else",
                                                    group: "craft-shared"), caller: craft)
            XCTFail("another owner's group")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .failedPrecondition)
            XCTAssertTrue(error.message.contains("another owner"), error.message)
        }

        do {
            _ = try await stack.query.index(request([item("ambient/turn/other", text: "Other lane.")], group: "craft-shared"),
                                            caller: ambient)
            XCTFail("another lane's group")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .failedPrecondition)
            XCTAssertTrue(error.message.contains("lane"), error.message)
        }
        await stack.database.shutdown()
    }

    // MARK: - T5, T6, T7: described partitions

    private func described(_ embedding: [Float], url: String = "") -> Thread_V1_ThreadPartitionInput {
        var p = Thread_V1_ThreadPartitionInput()
        p.embedding = embedding
        p.url = url
        return p
    }

    private func picture(_ id: String, vectors: [[Float]], urls: [String]) -> Thread_V1_ThreadIndexItem {
        var item = Thread_V1_ThreadIndexItem()
        item.documentID = id
        item.mediaType = "image"
        item.texts = ["a caption"] + Array(repeating: "", count: vectors.count - 1)
        item.partitions = zip(vectors, urls).map { described($0, url: $1) }
        return item
    }

    func testAHitCarriesItsPartitionsOwnURL() async throws {
        let stack = await makeStack()
        let base = "aii:veil/image/img-5"
        try await file(stack, request([
            picture("veil/image/img-5", vectors: [RecordingEmbeddingProvider.vector(for: "caption"),
                                                  RecordingEmbeddingProvider.vector(for: "tile")],
                    urls: [base, base + "#xywh=pixel:0,0,32,32"]),
            item("veil/image/plain", text: "a plain caption with no address"),
        ], group: "veil-pictures"), as: craft)

        var search = Thread_V1_ThreadSearchRequest()
        search.ownerID = owner
        search.queryText = "zzz"
        search.scope = "personal"
        search.aggregate = true
        search.topK = 10
        search.includeMetadata = true
        let hits = try await stack.query.search(search, caller: craft).results
        let urls = Set(hits.filter { $0.documentID == "veil/image/img-5" }.map(\.url))
        XCTAssertEqual(urls, [base, base + "#xywh=pixel:0,0,32,32"])
        let plain = try XCTUnwrap(hits.first { $0.documentID == "veil/image/plain" })
        XCTAssertEqual(plain.url, "", "a partition addressed by its document carries no url")

        search.includeMetadata = false
        let bare = try await stack.query.search(search, caller: craft).results
        XCTAssertTrue(bare.allSatisfy { $0.url.isEmpty }, "only when asked")
        await stack.database.shutdown()
    }

    func testIdenticalVectorsInOneDocumentKeepDistinctPartitions() async throws {
        let stack = await makeStack()
        let tile = RecordingEmbeddingProvider.vector(for: "the same tile")
        try await file(stack, request([
            picture("veil/image/twins", vectors: [RecordingEmbeddingProvider.vector(for: "caption"), tile, tile],
                    urls: ["", "#xywh=pixel:0,0,32,32", "#xywh=pixel:32,0,32,32"]),
        ], group: "veil-pictures"), as: craft)
        let parts = try XCTUnwrap(stack.database.partitionDatas(for: "veil/image/twins"))
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(Set(parts.map(\.id)).count, 3, "each partition keeps its own id")
        await stack.database.shutdown()
    }

    func testASuppliedVectorOfAnotherSizeIsRefused() async throws {
        let stack = await makeStack(embedder: SpacedEmbeddingProvider())
        do {
            _ = try await stack.query.index(request([
                picture("veil/image/small", vectors: [VectorFixtures.random(dim: 32, seed: 1), VectorFixtures.random(dim: 32, seed: 2)],
                        urls: ["", ""]),
            ], group: "veil-pictures"), caller: craft)
            XCTFail("32 dimensions in a 1024-dimension index")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .invalidArgument)
            XCTAssertTrue(error.message.contains("1024"), error.message)
        }
        try await file(stack, request([
            picture("veil/image/fits", vectors: [VectorFixtures.random(dim: dim, seed: 1), VectorFixtures.random(dim: dim, seed: 2)],
                    urls: ["", ""]),
        ], group: "veil-pictures"), as: craft)
        XCTAssertNotNil(stack.database.table?.index(for: "veil/image/fits"))
        await stack.database.shutdown()
    }
}
