//
//  Flow32_ExtractorGateTests.swift
//  ThreadTests
//
//  Created by Ritesh Pakala on 11/07/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  The extractor gate and the code-relations line: on the device one reading at a time, never while
//  an app generates, nothing while switched off, the model let go when idle or switched off; filings
//  wait in one line where the newest filing of a document is the one read.
//

import XCTest
import Logging
@testable import Thread

/// One logger for the file, so a task's closure never captures the test case.
private let flow32Logger = Logger(label: "flow32")

final class Flow32_ExtractorGateTests: XCTestCase {
    /// Counts readings in flight; each reading may be held until `open()`. Tracks loads and releases like a model.
    private actor Model: ReleasableExtractor {
        let holdsReadings: Bool
        private(set) var inFlight = 0
        private(set) var most = 0
        private(set) var asked: [String] = []
        private(set) var releases = 0
        private var loaded = false
        private var holds: [CheckedContinuation<Void, Never>] = []

        init(holdsReadings: Bool = false) { self.holdsReadings = holdsReadings }

        var isModelLoaded: Bool { loaded }
        var held: Int { holds.count }

        func releaseModel(logger: Logger) async -> Bool {
            guard loaded else { return false }
            loaded = false
            releases += 1
            return true
        }

        func extract(from texts: [String], logger: Logger) async throws -> Database.GraphPayload {
            _ = try await respond(instructions: "", input: texts.joined(), maxTokens: 1, logger: logger)
            return .init(entities: [.init(name: "read by the model", kind: "concept")])
        }

        func respond(instructions: String, input: String, maxTokens: Int, logger: Logger) async throws -> String? {
            loaded = true
            inFlight += 1
            most = max(most, inFlight)
            if holdsReadings {
                await withCheckedContinuation { holds.append($0) }
            } else {
                try? await Task.sleep(nanoseconds: 3_000_000)
            }
            inFlight -= 1
            asked.append(input)
            return #"{"goals":[{"type":"Store","goal":"persist settings between launches"}]}"#
        }

        func open() {
            let waiting = holds
            holds.removeAll()
            for hold in waiting { hold.resume() }
        }
    }

    private var logger: Logger { flow32Logger }

    private func gate(_ model: Model, backend: GraphExtractorGate.Backend = .mlx, idle: TimeInterval = 0,
                      busy: LockedValue<[String]> = LockedValue([])) -> GraphExtractorGate {
        GraphExtractorGate(inner: model, backend: backend, model: "test/model", logger: flow32Logger, enabled: true,
                           persist: false, idleRelease: idle, pollInterval: 0.01,
                           busyApps: { busy.withLock { $0 } })
    }

    private func until(_ timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await condition()
    }

    /// PIN: on the device the door admits one reading; eight callers at once never put two generations on the GPU.
    func test_onTheDevice_oneReadingAtATime() async throws {
        let model = Model()
        let door = gate(model)
        try await withThrowingTaskGroup(of: String?.self) { group in
            for i in 0..<8 {
                group.addTask { try await door.respond(instructions: "", input: "reading \(i)", maxTokens: 8, logger: flow32Logger) }
            }
            for try await answer in group { XCTAssertNotNil(answer) }
        }
        let most = await model.most
        let asked = await model.asked.count
        XCTAssertEqual(most, 1, "never two readings on the device at once")
        XCTAssertEqual(asked, 8, "every reading is answered in turn")
        let readings = await door.state.readings
        XCTAssertEqual(readings, 8)
    }

    /// PIN: a reading at the door waits while an app's busy mark is live, then reads.
    func test_aReadingWaitsWhileAnAppGenerates() async throws {
        let model = Model()
        let busy = LockedValue(["craft"])
        let door = gate(model, busy: busy)
        let reading = Task { try await door.respond(instructions: "", input: "after the turn", maxTokens: 8, logger: flow32Logger) }
        let yielding = await until { await door.state.yieldingTo == ["craft"] }
        XCTAssertTrue(yielding, "the door reports whom it waits for")
        let early = await model.asked
        XCTAssertTrue(early.isEmpty, "nothing reads while Craft generates")
        busy.withLock { $0 = [] }
        let answer = try await reading.value
        XCTAssertNotNil(answer)
        let state = await door.state
        XCTAssertEqual(state.yieldingTo, [])
        XCTAssertFalse(state.reading)
    }

    /// PIN: off lets the waiting readings go at once, answers extraction with keywords, and releases the model as
    /// soon as the reading that held the door ends.
    func test_switchingOff_letsWaitingReadingsGo_andReleasesTheModel() async throws {
        let model = Model(holdsReadings: true)
        let door = gate(model)
        let holder = Task { try await door.respond(instructions: "", input: "holds the door", maxTokens: 8, logger: flow32Logger) }
        _ = await until { await model.held == 1 }
        let second = Task { try await door.respond(instructions: "", input: "waits", maxTokens: 8, logger: flow32Logger) }
        let third = Task { try await door.respond(instructions: "", input: "waits too", maxTokens: 8, logger: flow32Logger) }
        let queued = await until { await door.state.waiting == 2 }
        XCTAssertTrue(queued)

        let state = await door.setEnabled(false)
        XCTAssertFalse(state.enabled)
        let secondAnswer = try await second.value
        let thirdAnswer = try await third.value
        XCTAssertNil(secondAnswer, "a waiting reading is let go")
        XCTAssertNil(thirdAnswer)
        let keywords = try await door.extract(from: ["Persist settings between launches of the settings store"], logger: logger)
        XCTAssertFalse(keywords.entities.contains { $0.name == "read by the model" }, "off: keyword entities, no model")

        let releasesWhileHeld = await model.releases
        XCTAssertEqual(releasesWhileHeld, 0, "never released under a reading")
        await model.open()
        let holderAnswer = try await holder.value
        XCTAssertNotNil(holderAnswer, "the reading that held the door finishes")
        let released = await until { await model.releases == 1 }
        XCTAssertTrue(released, "released once the door is free")

        await door.setEnabled(true)
        let again = Task { try await door.respond(instructions: "", input: "on again", maxTokens: 8, logger: flow32Logger) }
        _ = await until { await model.held == 1 }
        await model.open()
        let answer = try await again.value
        XCTAssertNotNil(answer, "on again, the next reading loads the model")
    }

    /// PIN: an idle model is let go after the idle time; the next reading loads it again.
    func test_anIdleModelIsReleased() async throws {
        let model = Model()
        let door = gate(model, idle: 0.05)
        _ = try await door.respond(instructions: "", input: "one", maxTokens: 8, logger: logger)
        let released = await until(2) { await model.releases == 1 }
        XCTAssertTrue(released)
        let loaded = await door.state.loaded
        XCTAssertFalse(loaded)
        _ = try await door.respond(instructions: "", input: "two", maxTokens: 8, logger: logger)
        let reloaded = await door.state.loaded
        XCTAssertTrue(reloaded)
    }

    /// PIN: a hosted backend uses no GPU here: readings neither queue nor wait for a busy app.
    func test_aHostedBackend_neitherQueuesNorWaits() async throws {
        let model = Model(holdsReadings: true)
        let door = gate(model, backend: .mistral, busy: LockedValue(["craft"]))
        let a = Task { try await door.respond(instructions: "", input: "a", maxTokens: 8, logger: flow32Logger) }
        let b = Task { try await door.respond(instructions: "", input: "b", maxTokens: 8, logger: flow32Logger) }
        let both = await until { await model.held == 2 }
        XCTAssertTrue(both, "two hosted readings at once, while Craft is busy")
        await model.open()
        _ = try await a.value
        _ = try await b.value
    }

    // MARK: - The code-relations line

    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("thread-flow32-\(UUID().uuidString)")
        FilePersistence.configure(dataDirectory: tempRoot.path)
    }

    override func tearDown() {
        FilePersistence.configure(dataDirectory: nil)
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    private func codeItem(_ id: String, text: String) -> Database.BatchPutItem {
        Database.BatchPutItem(id: id, data: [], texts: [text],
                              graph: .init(entities: [.init(name: "project:abc", kind: "project"),
                                                      .init(name: "module:App", kind: "module"),
                                                      .init(name: "sym:Store", kind: "struct")],
                                           relationships: [.init(subject: "module:App", predicate: "declares", object: "sym:Store")]),
                              mediaType: .code)
    }

    private func line(capacity: Int = CodeRelationQueue.defaultCapacity, busy: LockedValue<[String]>)
        async -> (Model, GraphExtractorGate, CodeRelationQueue) {
        let database = Database(nodeId: UUID(uuidString: "00000000-0000-0000-0000-0000000032a1")!)
        await database.initializationTask.value
        let model = Model()
        let door = gate(model, busy: busy)
        let queue = CodeRelationQueue(database: database, extractor: door, embedder: RecordingEmbeddingProvider(),
                                      capacity: capacity, accepts: { await door.isEnabled })
        return (model, door, queue)
    }

    /// PIN: filings only enqueue; one worker reads; a document filed again while it waits is read once, as filed last.
    func test_codeRelations_waitInOneLine_andTheNewestFilingIsRead() async throws {
        let busy = LockedValue(["craft"])
        let (model, door, queue) = await line(busy: busy)
        let request = DatabaseRequest(ownerId: "aii-local")
        await queue.enqueue([codeItem("d1", text: "struct Store {} // one"), codeItem("d2", text: "struct Store {} // first filing")], request: request)
        _ = await until { await door.state.reading }   // d1 holds the door, waiting for Craft
        await queue.enqueue([codeItem("d2", text: "struct Store {} // second filing"), codeItem("d3", text: "struct Store {} // three")], request: request)
        let pending = await queue.pending
        XCTAssertEqual(pending, 2, "d2 keeps its place and takes the newer item")

        busy.withLock { $0 = [] }
        await queue.drained()
        let asked = await model.asked
        XCTAssertEqual(asked.count, 3, "d1, d2 once, d3")
        XCTAssertTrue(asked.contains { $0.contains("second filing") })
        XCTAssertFalse(asked.contains { $0.contains("first filing") }, "the older filing of d2 is never read")
        let most = await model.most
        XCTAssertEqual(most, 1)
        let read = await queue.read
        XCTAssertEqual(read, 3)
    }

    /// PIN: switched off, the waiting readings go and new filings enqueue nothing; past capacity the oldest go.
    func test_codeRelations_offLetsThemGo_andTheLineHoldsItsCapacity() async throws {
        let busy = LockedValue(["craft"])
        let (_, door, queue) = await line(capacity: 2, busy: busy)
        let request = DatabaseRequest(ownerId: "aii-local")
        await queue.enqueue((1...4).map { codeItem("c\($0)", text: "struct Store {} // \($0)") }, request: request)
        let dropped = await queue.dropped
        XCTAssertEqual(dropped, 2, "four into a line of two: the two oldest go")
        _ = await until { await door.state.reading }
        let pending = await queue.pending
        XCTAssertEqual(pending, 1, "one at the door, one waiting")

        await door.setEnabled(false)
        let cleared = await queue.clear()
        XCTAssertEqual(cleared, 1)
        await queue.enqueue([codeItem("c9", text: "struct Store {}")], request: request)
        let afterOff = await queue.pending
        XCTAssertEqual(afterOff, 0, "off: filings enqueue nothing")
        busy.withLock { $0 = [] }
        await queue.drained()
    }
}
