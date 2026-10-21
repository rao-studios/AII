//
//  LaneIsolationTests.swift
//  ThreadTests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  One Thread, two lanes, the same owner in both. Nothing an app files, searches,
//  lists, exports, edits, removes or clears reaches the other lane. The stack
//  identity reads everything and writes nothing. Driven through the gRPC impls
//  with a shared-stack resolver, the way a direct client and Sewn's session reach
//  them.
//

import AII
import GRPCCore
import Seam
import XCTest
@testable import Thread

final class LaneIsolationTests: XCTestCase {
    private var tempRoot: URL!
    private let owner = "one-account"

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("thread-lanes-\(UUID().uuidString)")
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
        let graph: ThreadGraphServiceImpl
        let update: ThreadUpdateServiceImpl
    }

    private func makeStack() async -> Stack {
        let database = Database(nodeId: UUID(uuidString: "00000000-0000-0000-0000-00000000a11e")!)
        await database.initializationTask.value
        let provider = MockEmbeddingProvider()
        let resolver = LaneResolver.test
        return Stack(
            database: database,
            query: ThreadQueryServiceImpl(database: database, embeddingProvider: provider,
                                          graphExtractor: KeywordGraphExtractionProvider(), resolver: resolver),
            library: ThreadLibraryServiceImpl(database: database, resolver: resolver),
            graph: ThreadGraphServiceImpl(database: database, embeddingProvider: provider, resolver: resolver),
            update: ThreadUpdateServiceImpl(database: database, resolver: resolver))
    }

    /// Ambient's lane is `.a`, Craft's `.b` (Fixtures).
    private let ambient = LaneCaller.metadata(.presenting("ambient-secret"))
    private let craft = LaneCaller.metadata(.presenting("craft-secret"))
    private let stack = LaneCaller.metadata(.presenting("aii-secret"))

    private func waitForIndexed(_ id: String, in database: Database, timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if database.table?.keys.contains(id) == true { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("document \(id) was not indexed within \(timeout)s")
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

    private func indexRequest(id: String, text: String, group: String,
                              entities: [(String, String)] = []) -> Thread_V1_ThreadIndexRequest {
        var item = Thread_V1_ThreadIndexItem()
        item.documentID = id
        item.texts = [text]
        item.entities = entities.map { name, kind in
            var e = Thread_V1_ThreadGraphEntityIn()
            e.name = name
            e.kind = kind
            return e
        }
        var request = Thread_V1_ThreadIndexRequest()
        request.ownerID = owner
        request.groupID = group
        request.groupLabel = group
        request.items = [item]
        return request
    }

    private func index(_ stack: Stack, id: String, text: String, group: String,
                       entities: [(String, String)] = [], as caller: LaneCaller) async throws {
        _ = try await stack.query.index(indexRequest(id: id, text: text, group: group, entities: entities), caller: caller)
        await waitForIndexed(id, in: stack.database)
    }

    /// Two documents in each lane, one entity each lane's own and one both share.
    private func fill(_ stack: Stack) async throws {
        try await index(stack, id: "ambient-1", text: "Ada Lovelace described the analytical engine.",
                        group: "ambient-reading", entities: [("Ada Lovelace", "person"), ("Analytical Engine", "work")],
                        as: ambient)
        try await index(stack, id: "ambient-2", text: "A second page Ambient read.", group: "ambient-reading",
                        entities: [("Ambient Only", "concept")], as: ambient)
        try await index(stack, id: "craft-1", text: "Craft remembers the analytical engine too.",
                        group: "craft-memory", entities: [("Analytical Engine", "work"), ("Craft Only", "concept")],
                        as: craft)
        try await index(stack, id: "craft-2", text: "A code card about Session.send.", group: "craft-code",
                        entities: [("Session", "concept")], as: craft)
    }

    private func search(_ stack: Stack, text: String, as caller: LaneCaller) async throws -> Set<String> {
        var request = Thread_V1_ThreadSearchRequest()
        request.ownerID = owner
        request.queryText = text
        request.scope = "personal"
        request.aggregate = true
        return Set(try await stack.query.search(request, caller: caller).results.map(\.documentID))
    }

    private func libraryGroups(_ stack: Stack, as caller: LaneCaller) async throws -> Set<String> {
        var request = Thread_V1_ThreadLibraryRequest()
        request.ownerID = owner
        return Set(try await stack.library.library(request, caller: caller).groups.map(\.id))
    }

    private func documents(_ stack: Stack, ids: [String], as caller: LaneCaller) async throws -> Set<String> {
        var request = Thread_V1_ThreadDocumentsRequest()
        request.ownerID = owner
        request.documentIds = ids
        return Set(try await stack.library.documents(request, caller: caller).documents.map(\.id))
    }

    private func export(_ stack: Stack, as caller: LaneCaller) async throws -> Set<String> {
        var request = Thread_V1_ThreadExportCorpusRequest()
        request.ownerID = owner
        return Set(try await stack.library.exportCorpus(request, caller: caller).documents.map(\.id))
    }

    // MARK: - Reads

    func testEveryReadIsCutToTheCallersLane() async throws {
        let stack = await makeStack()
        try await fill(stack)
        let all: Set<String> = ["ambient-1", "ambient-2", "craft-1", "craft-2"]

        // The prose instrument gates on the graph: a query naming the engine scans only
        // the documents that mention it — one per lane here — and never the other lane's.
        let observed1 = try await search(stack, text: "analytical engine", as: ambient)
        XCTAssertEqual(observed1, ["ambient-1"])
        let observed2 = try await search(stack, text: "analytical engine", as: craft)
        XCTAssertEqual(observed2, ["craft-1"])
        let everything = try await search(stack, text: "analytical engine", as: self.stack)
        XCTAssertEqual(everything, ["ambient-1", "craft-1"], "the stack identity reads every lane")

        let observed3 = try await libraryGroups(stack, as: ambient)
        XCTAssertEqual(observed3, ["ambient-reading"])
        let observed4 = try await libraryGroups(stack, as: craft)
        XCTAssertEqual(observed4, ["craft-memory", "craft-code"])
        let observed5 = try await libraryGroups(stack, as: self.stack)
        XCTAssertEqual(observed5, ["ambient-reading", "craft-memory", "craft-code"])

        let observed6 = try await documents(stack, ids: Array(all), as: ambient)
        XCTAssertEqual(observed6, ["ambient-1", "ambient-2"])
        let observed7 = try await documents(stack, ids: Array(all), as: craft)
        XCTAssertEqual(observed7, ["craft-1", "craft-2"])
        let observed8 = try await documents(stack, ids: Array(all), as: self.stack)
        XCTAssertEqual(observed8, all)

        let observed9 = try await export(stack, as: ambient)
        XCTAssertEqual(observed9, ["ambient-1", "ambient-2"])
        let observed10 = try await export(stack, as: craft)
        XCTAssertEqual(observed10, ["craft-1", "craft-2"])
        await stack.database.shutdown()
    }

    func testTheGraphIsOneButEachLaneSeesItsOwnProvenance() async throws {
        let stack = await makeStack()
        try await fill(stack)

        var browse = Thread_V1_ThreadGraphQueryRequest()
        browse.ownerID = owner
        browse.limit = 50
        browse.includeDocuments = true

        let ambientView = try await stack.graph.query(browse, caller: ambient)
        let ambientNames = Set(ambientView.entities.map(\.name))
        XCTAssertTrue(ambientNames.contains("Ada Lovelace"))
        XCTAssertTrue(ambientNames.contains("Analytical Engine"), "shared: both lanes mention it")
        XCTAssertFalse(ambientNames.contains("Craft Only"), "no document of this lane mentions it")
        let sharedFromAmbient = ambientView.entities.first { $0.name == "Analytical Engine" }
        XCTAssertEqual(Set(sharedFromAmbient?.documentIds ?? []), ["ambient-1"], "provenance is cut to the lane")
        XCTAssertEqual(Set(ambientView.documents.map(\.id)), ["ambient-1", "ambient-2"])
        XCTAssertEqual(ambientView.stats.entityCount, 3, "Ada, the engine, Ambient Only")
        XCTAssertTrue(ambientView.stats.lanes.isEmpty, "per-lane counts are the stack identity's")

        let craftView = try await stack.graph.query(browse, caller: craft)
        let craftNames = Set(craftView.entities.map(\.name))
        XCTAssertEqual(craftNames, ["Analytical Engine", "Craft Only", "Session"])
        XCTAssertEqual(craftView.stats.entityCount, 3)

        let stackView = try await stack.graph.query(browse, caller: self.stack)
        XCTAssertEqual(stackView.stats.entityCount, 5, "one graph: the shared entity counts once")
        XCTAssertEqual(stackView.stats.lanes.count, 2)
        let byLane = Dictionary(uniqueKeysWithValues: stackView.stats.lanes.map { ($0.lane, $0) })
        XCTAssertEqual(byLane[LaneID.a.rawValue]?.documents, 2)
        XCTAssertEqual(byLane[LaneID.a.rawValue]?.entities, 3)
        XCTAssertEqual(byLane[LaneID.b.rawValue]?.documents, 2)
        XCTAssertEqual(byLane[LaneID.b.rawValue]?.groups, 2)
        await stack.database.shutdown()
    }

    func testStatsAnswerForTheCallersLane() async throws {
        let stack = await makeStack()
        try await fill(stack)
        let request = Thread_V1_ThreadStatsRequest()

        let ambientStats = try await stack.update.stats(request, caller: ambient)
        XCTAssertEqual(ambientStats.documentCount, 2)
        XCTAssertEqual(ambientStats.groupCount, 1)
        XCTAssertEqual(ambientStats.ownerCount, 1)
        XCTAssertTrue(ambientStats.lanes.isEmpty)

        let craftStats = try await stack.update.stats(request, caller: craft)
        XCTAssertEqual(craftStats.documentCount, 2)
        XCTAssertEqual(craftStats.groupCount, 2)

        let stackStats = try await stack.update.stats(request, caller: self.stack)
        XCTAssertEqual(stackStats.documentCount, 4)
        XCTAssertEqual(stackStats.groupCount, 3)
        XCTAssertEqual(stackStats.ownerCount, 1, "one account across both lanes")
        XCTAssertEqual(Set(stackStats.lanes.map(\.lane)), [LaneID.a.rawValue, LaneID.b.rawValue])

        let own = stack.database.stats(lane: .a)
        XCTAssertEqual(own.documents, 2)
        XCTAssertEqual(own.relationships, 0, "no relationships were deposited")
        XCTAssertEqual(own.topEntities.count, 3)
        await stack.database.shutdown()
    }

    // MARK: - Writes

    func testADocumentAnotherLaneFiledIsRefusedByName() async throws {
        let stack = await makeStack()
        try await fill(stack)

        do {
            _ = try await stack.query.index(indexRequest(id: "ambient-1", text: "the same id from Craft", group: "craft-memory"),
                                            caller: craft)
            XCTFail("a document in another lane must not be re-filed")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .failedPrecondition)
            XCTAssertTrue(error.message.contains("Ambient"), "the other lane is named by its app: \(error.message)")
        }
        XCTAssertEqual(stack.database.registry?.lane(of: "ambient-1"), .a)
        XCTAssertEqual(stack.database.registry?.isOwnerLinked("ambient-1", ownerId: owner), true)

        // The authoritative guard: a put that slipped past the pre-check is dropped.
        let item = Database.BatchPutItem(id: "craft-1", data: [EmbeddingData(embedding: .floats(VectorFixtures.random(dim: 1024, seed: 7)), index: 0)],
                                         texts: ["smuggled"])
        await stack.database.putBatch([item], request: DatabaseRequest(ownerId: owner, lane: .a))
        XCTAssertEqual(stack.database.registry?.lane(of: "craft-1"), .b, "the lane did not move")
        XCTAssertEqual(stack.database.partitionDatas(for: "craft-1")?.first?.data, "Craft remembers the analytical engine too.",
                       "the content did not change")
        await stack.database.shutdown()
    }

    func testTheStackIdentityWritesNothing() async throws {
        let stack = await makeStack()
        for attempt: () async throws -> Void in [
            { _ = try await stack.query.index(self.indexRequest(id: "stack-1", text: "filed by the stack", group: "g"), caller: self.stack) },
            { var r = Thread_V1_ThreadRemoveRequest(); r.ownerID = self.owner
              _ = try await stack.query.remove(r, caller: self.stack) },
            { var r = Thread_V1_ThreadUpdateGroupRequest(); r.ownerID = self.owner; r.groupID = "g"; r.label = "x"
              _ = try await stack.update.updateGroup(r, caller: self.stack) },
            { var r = Thread_V1_ThreadUpdateDocumentRequest(); r.ownerID = self.owner; r.documentID = "d"; r.access = "available"
              _ = try await stack.update.updateDocument(r, caller: self.stack) },
        ] {
            do {
                try await attempt()
                XCTFail("the stack identity has no lane to write into")
            } catch let error as RPCError {
                XCTAssertEqual(error.code, .failedPrecondition)
            }
        }
        XCTAssertEqual(stack.database.table?.keys.isEmpty, true)
        await stack.database.shutdown()
    }

    func testAnUnknownSecretIsRefused() async throws {
        let stack = await makeStack()
        var request = Thread_V1_ThreadSearchRequest()
        request.ownerID = owner
        request.queryText = "anything"
        do {
            _ = try await stack.query.search(request, caller: .metadata(.presenting("stranger")))
            XCTFail("an unknown secret has no lane")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .unauthenticated)
        }
        // A direct client naming a lane in the message is ignored: the secret decides.
        request.lane = LaneID.b.rawValue
        try await fill(stack)
        let observed11 = try await stack.query.search(request, caller: ambient).results.isEmpty
        XCTAssertEqual(observed11, false)
        var hits = Set<String>()
        for result in try await stack.query.search(request, caller: ambient).results { hits.insert(result.documentID) }
        XCTAssertTrue(hits.isSubset(of: ["ambient-1", "ambient-2"]), "\(hits)")
        await stack.database.shutdown()
    }

    func testUpdatesAndRemovalsStayInLane() async throws {
        let stack = await makeStack()
        try await fill(stack)

        // Craft cannot rename Ambient's group, move Ambient's document, or change its access.
        var rename = Thread_V1_ThreadUpdateGroupRequest()
        rename.ownerID = owner
        rename.groupID = "ambient-reading"
        rename.label = "Taken"
        let observed12 = try await stack.update.updateGroup(rename, caller: craft).success
        XCTAssertFalse(observed12)
        let observed13 = try await stack.update.updateGroup(rename, caller: ambient).success
        XCTAssertTrue(observed13)
        XCTAssertEqual(stack.database.groups(for: owner, lane: .a).first?.label, "Taken")

        var move = Thread_V1_ThreadUpdateDocumentRequest()
        move.ownerID = owner
        move.documentID = "ambient-1"
        move.groupID = "craft-memory"
        let observed14 = try await stack.update.updateDocument(move, caller: craft).success
        XCTAssertFalse(observed14)
        move.access = "available"
        move.groupID = ""
        let observed15 = try await stack.update.updateDocument(move, caller: craft).success
        XCTAssertFalse(observed15)
        XCTAssertEqual(stack.database.registry?.getDocumentAccess("ambient-1"), .restricted)

        // Removing by id from the wrong lane is a no-op; from the right lane it lands.
        var remove = Thread_V1_ThreadRemoveRequest()
        remove.ownerID = owner
        remove.documentIds = ["ambient-1"]
        _ = try await stack.query.remove(remove, caller: craft)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(stack.database.table?.keys.contains("ambient-1"), true)
        _ = try await stack.query.remove(remove, caller: ambient)
        await waitUntil({ stack.database.table?.keys.contains("ambient-1") == false }, "removed from its own lane")

        // Remove with no ids wipes the owner's documents in that lane alone.
        remove.documentIds = []
        let wiped = try await stack.query.remove(remove, caller: craft)
        XCTAssertEqual(wiped.removedCount, 2)
        XCTAssertEqual(stack.database.table?.keys, ["ambient-2"], "Ambient's remaining document survived Craft's wipe")
        XCTAssertEqual(stack.database.registry?.laneGroups[.b], nil, "Craft's groups went with its documents")
        XCTAssertEqual(stack.database.registry?.laneGroups[.a], ["ambient-reading"])
        await stack.database.shutdown()
    }

    func testAClearTakesOneLaneAndLeavesTheOther() async throws {
        let stack = await makeStack()
        await stack.database.reconcileEmbedder(vectorSpace: "test@1024", model: "mock", revision: nil)
        try await fill(stack)

        let removed = await stack.database.clear(lane: .b)
        XCTAssertEqual(removed.documents, 2)
        XCTAssertEqual(removed.entities, 2, "Craft Only and Session; the shared engine survives with Ambient")
        XCTAssertEqual(stack.database.table?.keys, ["ambient-1", "ambient-2"])
        XCTAssertEqual(stack.database.graph?.entities.values.map(\.name).sorted(), ["Ada Lovelace", "Ambient Only", "Analytical Engine"])
        XCTAssertEqual(stack.database.graph?.entities.values.first { $0.name == "Analytical Engine" }?.documentIds, ["ambient-1"])
        XCTAssertNil(stack.database.partitionDatas(for: "craft-1"), "the lane's files are purged")
        XCTAssertNotNil(stack.database.partitionDatas(for: "ambient-1"))
        let state = await stack.database.indexState
        XCTAssertEqual(state, .matches, "a filled table keeps its stamp")

        let rest = await stack.database.clear(lane: .a)
        XCTAssertEqual(rest.documents, 2)
        XCTAssertEqual(stack.database.table?.keys.isEmpty, true)
        XCTAssertEqual(stack.database.graph?.entities.isEmpty, true)
        XCTAssertEqual(stack.database.registry?.ownersDocuments.isEmpty, true, "no owner is left holding nothing")
        await stack.database.shutdown()
    }

    func testTheLaneStatsCacheRecomputesOnlyWhenTheStoresChange() async throws {
        let stack = await makeStack()
        try await fill(stack)
        let cache = stack.database.laneStats
        let before = cache.passes
        _ = stack.database.stats(lane: .a)
        _ = stack.database.stats(lane: .b)
        _ = stack.database.statsByLane()
        XCTAssertEqual(cache.passes, before + 1, "one pass serves every lane")

        // A change within the debounce window is served from the last pass; after it,
        // a fresh pass sees the change.
        try await index(stack, id: "ambient-3", text: "a third page", group: "ambient-reading", as: ambient)
        _ = stack.database.stats(lane: .a)
        XCTAssertEqual(cache.passes, before + 1, "within the debounce: still the last pass")
        let fresh = cache.read(key: .init(table: stack.database.nonisolatedTableMutator.mutationVersion,
                                          registry: stack.database.nonisolatedRegistryMutator.mutationVersion),
                               registry: stack.database.registry, table: stack.database.table,
                               graph: stack.database.graph, now: Date().addingTimeInterval(60))
        XCTAssertEqual(cache.passes, before + 2)
        XCTAssertEqual(fresh.byLane[.a]?.documents, 3)
        await stack.database.shutdown()
    }
}
