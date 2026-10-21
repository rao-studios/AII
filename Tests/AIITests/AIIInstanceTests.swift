//
//  AIIInstanceTests.swift
//  AIITests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  AIIInstance against a fake Thread wire and a stubbed Sewn stream: what it files, under
//  whom and where; waiting until Thread holds the version just sent; one remember at a
//  time; supersession after the deposit; recall decoding the app's own type, Sewn's memory
//  and a hit's own url; forgetting records, groups and memory, never with an empty list;
//  the answer stream's events and errors; and the lane inspector the doctor reads.
//

import Foundation
import GRPCCore
import XCTest
@testable import AII
import Seam

/// Thread as AIIInstance sees it: what was asked, and canned answers.
final class FakeThreadWire: ThreadWire, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var indexed: [Thread_V1_ThreadIndexRequest] = []
    private(set) var searched: [Thread_V1_ThreadSearchRequest] = []
    private(set) var removed: [Thread_V1_ThreadRemoveRequest] = []
    private(set) var removedGroups: [Thread_V1_ThreadRemoveGroupsRequest] = []
    /// Every call, in order: "index", "documents", "search", "remove", "removeGroups",
    /// "library", "exportCorpus".
    private(set) var calls: [String] = []
    var searchResults: [Thread_V1_ThreadPartitionResult] = []
    var libraryGroups: [Thread_V1_ThreadGroup] = []
    var corpus: [Thread_V1_ThreadDocumentContent] = []
    var failure: RPCError?
    /// Thread files what it accepts after this many reads, serving what it held before
    /// until then; never, when `neverFiles`.
    var unfiledReads = 0
    var neverFiles = false
    /// The metadata Thread holds for each document, and what it has accepted but not filed.
    private var filed: [String: Data] = [:]
    private var accepted: [String: Data] = [:]

    func index(_ request: Thread_V1_ThreadIndexRequest) async throws -> Thread_V1_ThreadIndexResponse {
        try record("index") {
            indexed.append(request)
            for item in request.items { accepted[item.documentID] = item.metadata }
        }
        var response = Thread_V1_ThreadIndexResponse()
        response.success = true
        response.indexedCount = Int32(request.items.count)
        return response
    }

    func search(_ request: Thread_V1_ThreadSearchRequest) async throws -> Thread_V1_ThreadSearchResponse {
        try record("search") { searched.append(request) }
        var response = Thread_V1_ThreadSearchResponse()
        response.results = lock.withLock { searchResults }
        return response
    }

    func remove(_ request: Thread_V1_ThreadRemoveRequest) async throws -> Thread_V1_ThreadRemoveResponse {
        try record("remove") { removed.append(request) }
        return Thread_V1_ThreadRemoveResponse()
    }

    func removeGroups(_ request: Thread_V1_ThreadRemoveGroupsRequest) async throws -> Thread_V1_ThreadRemoveGroupsResponse {
        try record("removeGroups") { removedGroups.append(request) }
        var response = Thread_V1_ThreadRemoveGroupsResponse()
        response.success = true
        response.removedGroupIds = request.groupIds
        response.removedDocumentCount = 2
        return response
    }

    func documents(_ request: Thread_V1_ThreadDocumentsRequest) async throws -> Thread_V1_ThreadDocumentsResponse {
        var response = Thread_V1_ThreadDocumentsResponse()
        try record("documents") {
            if unfiledReads > 0 {
                unfiledReads -= 1
            } else if !neverFiles {
                filed.merge(accepted) { _, new in new }
                accepted = [:]
            }
            response.documents = request.documentIds.compactMap { id in
                guard let metadata = filed[id] else { return nil }
                var content = Thread_V1_ThreadDocumentContent()
                content.id = id
                content.metadata = metadata
                return content
            }
        }
        return response
    }

    func library(_ request: Thread_V1_ThreadLibraryRequest) async throws -> Thread_V1_ThreadLibraryResponse {
        var response = Thread_V1_ThreadLibraryResponse()
        try record("library") { response.groups = libraryGroups }
        return response
    }

    func exportCorpus(_ request: Thread_V1_ThreadExportCorpusRequest) async throws -> Thread_V1_ThreadExportCorpusResponse {
        var response = Thread_V1_ThreadExportCorpusResponse()
        try record("exportCorpus") {
            response.documents = Array(corpus.prefix(Int(request.limit)))
            response.hasMore_p = corpus.count > Int(request.limit)
        }
        return response
    }

    private func record(_ call: String, _ body: () -> Void) throws {
        try lock.withLock {
            if let failure { throw failure }
            calls.append(call)
            body()
        }
    }

    static func hit(_ record: AIIRecord, text: String = "", url: String = "", score: Float = 0.1) throws -> Thread_V1_ThreadPartitionResult {
        var result = Thread_V1_ThreadPartitionResult()
        result.documentID = record.documentID
        result.partitionID = record.documentID + "#0"
        result.text = text
        result.url = url
        result.score = score
        result.name = record.title
        result.groupID = AIIRecord.groupID(app: record.app, group: record.group.id)
        result.metadata = try record.canonicalJSON()
        return result
    }
}

final class AIIInstanceTests: XCTestCase {

    private func makeInstance(_ test: TestHome, wire: FakeThreadWire, owner: AIIOwner? = nil, joined: Bool = true,
                              session: URLSession = AIIAnswer.makeSession(), filingTimeout: Duration = .seconds(15)) -> AIIInstance {
        AIIInstance(app: "notes", displayName: "Notes", bundleIdentifier: nil, owner: owner, home: test.home, bundle: nil,
                    appVersion: nil, supervisor: AIISupervisor(app: "notes", home: test.home), wire: wire, session: session,
                    joined: joined, filingTimeout: filingTimeout)
    }

    func testRememberFilesEachGroupUnderTheAppsOwner() async throws {
        let test = TestHome()
        let wire = FakeThreadWire()
        let aii = makeInstance(test, wire: wire)
        let filed = try await aii.remember([
            TestNote(recordID: "n1", title: "Stand-up", body: "Ada leads Joltvault."),
            TestTask(recordID: "t1", title: "Ship the index", due: Date(), replaces: nil),
            TestNote(recordID: "n2", title: "Retro", body: "What went well."),
        ])
        XCTAssertEqual(filed, 3)
        XCTAssertEqual(wire.indexed.count, 2, "one Index per group")
        XCTAssertEqual(wire.indexed.map(\.ownerID), ["local-notes", "local-notes"])
        XCTAssertEqual(wire.indexed.map(\.groupID), ["notes-notes", "notes-tasks"])
        XCTAssertEqual(wire.indexed.map(\.groupLabel), ["Notes", "Tasks"])
        XCTAssertEqual(wire.indexed[0].items.map(\.documentID), ["notes/note/n1", "notes/note/n2"])
        XCTAssertEqual(wire.indexed[0].items[0].texts, ["Ada leads Joltvault."])
        let envelope = try XCTUnwrap(AIIRecord.decode(wire.indexed[0].items[0].metadata))
        XCTAssertEqual(try envelope.value(as: TestNote.self)?.body, "Ada leads Joltvault.")
        XCTAssertTrue(wire.removed.isEmpty, "nothing superseded, nothing removed")
    }

    func testAnIndexMadeWithAnOwnerFilesAndAsksAsIt() async throws {
        let test = TestHome()
        let wire = FakeThreadWire()
        let aii = makeInstance(test, wire: wire, owner: .local)
        XCTAssertEqual(aii.owner, .local)
        try await aii.remember([TestNote(recordID: "n1", title: "x", body: "y")])
        XCTAssertEqual(wire.indexed.map(\.ownerID), ["aii-local"])
        XCTAssertEqual(wire.indexed.map(\.groupID), ["notes-notes"], "the app's own group, under the shared owner")
        _ = try await aii.recall("y")
        XCTAssertEqual(wire.searched.last?.ownerID, "aii-local")
        _ = try await aii.forgetMemory()
        XCTAssertEqual(wire.removedGroups.last?.groupIds, ["notes-memory-aii-local", "notes-resonance-aii-local"])
    }

    func testWithNoOwnerGivenTheLanesOwnerIsUsed() throws {
        let test = TestHome()
        try test.home.register("notes", owner: .local)
        XCTAssertEqual(makeInstance(test, wire: FakeThreadWire()).owner, .local, "the manifest's")
        try test.home.setOwner(.app("notes"), for: "notes")
        XCTAssertEqual(makeInstance(test, wire: FakeThreadWire()).owner, .app("notes"))
    }

    /// Thread may still hold the version before: remember returns once it holds this one.
    func testRememberingAnIdAgainWaitsForTheNewVersion() async throws {
        let test = TestHome()
        let wire = FakeThreadWire()
        let aii = makeInstance(test, wire: wire)
        try await aii.remember([TestNote(recordID: "n1", title: "Draft", body: "first")])
        wire.unfiledReads = 2
        try await aii.remember([TestNote(recordID: "n1", title: "Final", body: "second")])
        XCTAssertEqual(wire.calls, ["index", "documents", "index", "documents", "documents", "documents"])
    }

    func testRemembersRunOneAtATime() async throws {
        let test = TestHome()
        let wire = FakeThreadWire()
        let aii = makeInstance(test, wire: wire)
        async let first = aii.remember([TestNote(recordID: "n1", title: "a", body: "one")])
        async let second = aii.remember([TestNote(recordID: "n1", title: "b", body: "two")])
        _ = try await (first, second)
        XCTAssertEqual(wire.calls, ["index", "documents", "index", "documents"], "never interleaved")
    }

    func testSupersessionRemovesAfterTheDeposit() async throws {
        let test = TestHome()
        let wire = FakeThreadWire()
        let aii = makeInstance(test, wire: wire)
        try await aii.remember([TestTask(recordID: "t2", title: "Ship it", due: Date(), replaces: "t1")])
        XCTAssertEqual(wire.calls, ["index", "documents", "remove"], "filed and read back first: the group never empties")
        XCTAssertEqual(wire.removed.first?.documentIds, ["notes/task/t1"])
        XCTAssertEqual(wire.removed.first?.ownerID, "local-notes")
    }

    /// Thread answers Index before it has filed what it accepted: remember returns once it has.
    func testRememberWaitsUntilThreadHasFiledTheRecords() async throws {
        let test = TestHome()
        let wire = FakeThreadWire()
        wire.unfiledReads = 2
        let aii = makeInstance(test, wire: wire)
        try await aii.remember([TestNote(recordID: "n1", title: "x", body: "y")])
        XCTAssertEqual(wire.calls, ["index", "documents", "documents", "documents"])
    }

    func testRecordsNeverFiledReplaceNothing() async throws {
        let test = TestHome()
        let wire = FakeThreadWire()
        wire.neverFiles = true
        let aii = makeInstance(test, wire: wire, filingTimeout: .milliseconds(300))
        do {
            try await aii.remember([TestTask(recordID: "t2", title: "Ship it", due: Date(), replaces: "t1")])
            XCTFail("expected notReady")
        } catch let error as AIIInstanceError {
            guard case .notReady = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(wire.removed.isEmpty, "the record it replaces stays until the new one is filed")
    }

    func testRecallDecodesTheAppsTypeAndSewnsMemory() async throws {
        let test = TestHome()
        let wire = FakeThreadWire()
        let note = TestNote(recordID: "n1", title: "Stand-up", body: "Ada leads Joltvault.")
        let memory = AIIRecord(app: "notes", id: "abc123", kind: .memory, title: "Conversation memory",
                               group: .init(id: "memory-local-notes", label: "Memory"), source: .init(kind: "sewn-summary"))
        var foreign = Thread_V1_ThreadPartitionResult()
        foreign.documentID = "hand-deposited"
        foreign.text = "no envelope"
        wire.searchResults = [try FakeThreadWire.hit(memory, text: "We talked about Joltvault."),
                              try FakeThreadWire.hit(try note.envelope(app: "notes"), text: note.body), foreign]
        let aii = makeInstance(test, wire: wire)

        let notes = try await aii.recall("who leads Joltvault?", as: TestNote.self, topK: 5)
        XCTAssertEqual(notes.map(\.value), [note], "only that kind, as that type")
        XCTAssertEqual(notes.first?.hit.groupID, "notes-notes")
        let request = try XCTUnwrap(wire.searched.first)
        XCTAssertEqual(request.ownerID, "local-notes")
        XCTAssertTrue(request.includeMetadata)
        XCTAssertTrue(request.aggregate)
        XCTAssertEqual(request.topK, 15, "over-fetched: kinds are filtered here")

        let everything = try await aii.recall("Joltvault")
        XCTAssertEqual(everything.hits.compactMap(\.record?.kind), [.memory, .note])
        XCTAssertEqual(everything.hits.first?.record?.source.kind, "sewn-summary")
        XCTAssertNil(everything.hits.last?.record, "a document filed by hand holds no envelope")

        let memories = try await aii.recall("Joltvault", kinds: [.memory])
        XCTAssertEqual(memories.hits.map(\.documentID), ["notes/memory/abc123"])

        _ = try await aii.recall("Joltvault", in: ["notes"])
        XCTAssertEqual(wire.searched.last?.groupIds, ["notes-notes"])
        XCTAssertEqual(wire.searched.last?.aggregate, false)
    }

    func testAHitCarriesItsOwnURLAndRegion() async throws {
        let test = TestHome()
        let wire = FakeThreadWire()
        let picture = AIIRecord(app: "notes", id: "img-1", kind: .image, title: "harbor.png",
                                group: .init(id: "camera", label: "Camera"), mediaType: .image)
        wire.searchResults = [try FakeThreadWire.hit(picture, url: "file:///harbor.png#xywh=pixel:32,0,32,32"),
                              try FakeThreadWire.hit(picture, text: "Boats at dusk")]
        let aii = makeInstance(test, wire: wire)
        let found = try await aii.recall("boats")
        XCTAssertEqual(found.hits.map(\.url), ["file:///harbor.png#xywh=pixel:32,0,32,32", nil])
        XCTAssertEqual(found.hits.first?.region, AIIRecord.Region(x: 32, y: 0, width: 32, height: 32))
        XCTAssertNil(found.hits.last?.region)
    }

    func testForgettingNeverSendsAnEmptyList() async throws {
        let test = TestHome()
        let wire = FakeThreadWire()
        let aii = makeInstance(test, wire: wire)
        try await aii.forget([])
        try await aii.forget(documentIDs: [])
        let none = try await aii.forget(groups: [])
        XCTAssertEqual(none, AIIInstance.Forgotten(groups: [], documentCount: 0))
        XCTAssertEqual(wire.calls, [], "an empty Remove would remove everything the owner holds")

        try await aii.forget([TestNote(recordID: "n1", title: "x", body: "y")])
        XCTAssertEqual(wire.removed.last?.documentIds, ["notes/note/n1"])
        try await aii.forget(documentIDs: ["notes/memory/abc123"])
        XCTAssertEqual(wire.removed.last?.documentIds, ["notes/memory/abc123"])
    }

    func testForgettingGroupsAndMemory() async throws {
        let test = TestHome()
        let wire = FakeThreadWire()
        let aii = makeInstance(test, wire: wire)
        let groups = try await aii.forget(groups: ["standups", "tasks"])
        XCTAssertEqual(wire.removedGroups.last?.groupIds, ["notes-standups", "notes-tasks"])
        XCTAssertEqual(wire.removedGroups.last?.ownerID, "local-notes")
        XCTAssertEqual(groups, AIIInstance.Forgotten(groups: ["standups", "tasks"], documentCount: 2))

        let memory = try await aii.forgetMemory()
        XCTAssertEqual(wire.removedGroups.last?.groupIds, ["notes-memory-local-notes", "notes-resonance-local-notes"],
                       "Sewn's memory groups are the app's own")
        XCTAssertEqual(memory.groups, ["memory", "resonance"])
    }

    func testNothingBeforeJoining() async throws {
        let test = TestHome()
        let wire = FakeThreadWire()
        let aii = makeInstance(test, wire: wire, joined: false)
        do {
            try await aii.remember([TestNote(recordID: "n1", title: "x", body: "y")])
            XCTFail("expected notJoined")
        } catch let error as AIIInstanceError {
            XCTAssertEqual(error, .notJoined)
        }
        XCTAssertEqual(wire.calls, [])
    }

    func testThreadsRefusalsAreNamed() async throws {
        let test = TestHome()
        let wire = FakeThreadWire()
        wire.failure = RPCError(code: .unavailable, message: "the embedder is loading")
        let aii = makeInstance(test, wire: wire)
        do {
            _ = try await aii.recall("x")
            XCTFail("expected notReady")
        } catch let error as AIIInstanceError {
            XCTAssertEqual(error, .notReady("the embedder is loading"))
        }
        wire.failure = RPCError(code: .failedPrecondition, message: "document belongs to Craft's lane")
        do {
            try await aii.remember([TestNote(recordID: "n1", title: "x", body: "y")])
            XCTFail("expected refused")
        } catch let error as AIIInstanceError {
            XCTAssertEqual(error, .refused(code: "failedPrecondition", message: "document belongs to Craft's lane"))
        }
    }

    // MARK: - Asking

    private func stubbedSession(_ body: String, status: Int = 200) -> URLSession {
        StubSewn.response = (status, body)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubSewn.self]
        return URLSession(configuration: configuration)
    }

    func testAnAnswerStreamsReferencesTokensAndContribution() async throws {
        let test = TestHome()
        _ = try test.home.ensureSecret(for: AIIApp("notes"))
        let stream = """
        data: {"choices":[{"delta":{"role":"assistant"}}],"references":[{"id":"notes/note/n1","partition_id":"p0","owner_id":"local-notes"}],"auto_memory":false}

        data: {"choices":[{"delta":{"content":"Ada "}}],"references":[],"auto_memory":false}

        data: {"choices":[{"delta":{"content":"leads it."}}],"references":[],"auto_memory":false}

        data: {"choices":[],"references":[],"contribution":{"totalCost":3},"auto_memory":true}

        data: [DONE]

        """
        let aii = makeInstance(test, wire: FakeThreadWire(), session: stubbedSession(stream))
        var events: [AIIAnswer.Event] = []
        for try await event in aii.ask("Who leads Joltvault?") { events.append(event) }
        XCTAssertEqual(events, [
            .references([AIIAnswer.Reference(id: "notes/note/n1", partitionID: "p0", ownerID: "local-notes")]),
            .token("Ada "), .token("leads it."),
            .contribution(.object(["totalCost": .integer(3)])),
            .finished(autoMemory: true),
        ])

        let sent = try XCTUnwrap(StubSewn.lastRequest)
        XCTAssertEqual(sent.url?.host(), "127.0.0.1")
        XCTAssertEqual(sent.url?.path(), "/v1/chat/completions")
        XCTAssertEqual(sent.value(forHTTPHeaderField: StackSecret.headerName), try test.home.readSecret(for: AIIApp("notes")))
        let body = try XCTUnwrap(StubSewn.lastBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertNil(body["provider"], "named nothing: Sewn decides from the keys the stack holds")
        XCTAssertEqual(body["stream"] as? Bool, true)
        let sewn = try XCTUnwrap(body["sewn"] as? [String: Any])
        XCTAssertEqual(sewn["owner_id"] as? String, "local-notes")
        XCTAssertEqual(sewn["scope"] as? String, "personal")
    }

    func testAskCanPinThisMac() async throws {
        let test = TestHome()
        _ = try test.home.ensureSecret(for: AIIApp("notes"))
        let stream = """
        data: {"choices":[{"delta":{"content":"Ada"}}],"references":[],"auto_memory":false}

        data: [DONE]

        """
        let aii = makeInstance(test, wire: FakeThreadWire(), session: stubbedSession(stream))
        for try await _ in aii.ask("x", options: .init(provider: .local)) {}
        let body = try XCTUnwrap(StubSewn.lastBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(body["provider"] as? String, "local", "`.local` pins the Mac: nothing leaves it")
    }

    func testAnErrorInTheStreamIsThrown() async throws {
        let test = TestHome()
        _ = try test.home.ensureSecret(for: AIIApp("notes"))
        let stream = """
        data: {"choices":[{"delta":{"content":"Ada"}}],"references":[],"auto_memory":false}

        data: {"error":{"message":"the model ran out of memory"}}

        """
        let aii = makeInstance(test, wire: FakeThreadWire(), session: stubbedSession(stream))
        var tokens: [String] = []
        do {
            for try await event in aii.ask("x") { if case .token(let text) = event { tokens.append(text) } }
            XCTFail("expected the error")
        } catch let failure as AIIAnswer.Failure {
            XCTAssertEqual(failure.message, "the model ran out of memory")
        }
        XCTAssertEqual(tokens, ["Ada"])
    }

    func testARefusalBeforeTheStreamIsThrown() async throws {
        let test = TestHome()
        _ = try test.home.ensureSecret(for: AIIApp("notes"))
        let aii = makeInstance(test, wire: FakeThreadWire(), session: stubbedSession(#"{"error":"Missing or wrong X-Ambient-Secret"}"#, status: 401))
        do {
            for try await _ in aii.ask("x") {}
            XCTFail("expected the refusal")
        } catch let failure as AIIAnswer.Failure {
            XCTAssertEqual(failure.status, 401)
        }
    }
}

final class AIILaneInspectorTests: XCTestCase {

    private func content(_ id: String, metadata: Data) -> Thread_V1_ThreadDocumentContent {
        var content = Thread_V1_ThreadDocumentContent()
        content.id = id
        content.metadata = metadata
        return content
    }

    func testItReadsTheGroupsAndChecksASampleAgainstTheSchema() async throws {
        let wire = FakeThreadWire()
        var notes = Thread_V1_ThreadGroup()
        notes.id = "notes-notes"
        notes.label = "Notes"
        notes.ownerID = "aii-local"
        notes.documents = [Thread_V1_ThreadDocument(), Thread_V1_ThreadDocument()]
        var foreign = Thread_V1_ThreadGroup()
        foreign.id = "craft-records"
        foreign.ownerID = "someone-else"
        wire.libraryGroups = [notes, foreign]
        let good = try TestNote(recordID: "n1", title: "x", body: "y").envelope(app: "notes")
        let craft = try TestNote(recordID: "n2", title: "x", body: "y").envelope(app: .craft)
        wire.corpus = [
            content("notes/note/n1", metadata: try good.canonicalJSON()),
            content("hand-filed", metadata: Data(#"{"source":"script"}"#.utf8)),
            content("notes/note/n2", metadata: try craft.canonicalJSON()),
            content("notes/note/elsewhere", metadata: try good.canonicalJSON()),
        ]
        let inspection = try await AIILaneInspector.inspect(app: "notes", owner: .local, wire: wire, sampleSize: 3)
        XCTAssertEqual(inspection.owner, .local)
        XCTAssertEqual(inspection.groups, [AIILaneInspection.Group(id: "notes-notes", label: "Notes", documents: 2)],
                       "another owner's group isn't this owner's")
        XCTAssertEqual(inspection.sample.map(\.isRecord), [true, false, true])
        XCTAssertEqual(inspection.sample.map(\.recordApp), ["notes", nil, .craft])
        XCTAssertEqual(inspection.sample.map(\.idMatches), [true, false, false])
        XCTAssertFalse(inspection.sampledAll, "a fourth document wasn't read")
        XCTAssertEqual(wire.calls, ["library", "exportCorpus"])
    }
}

/// Sewn's chat route, answered from a script.
final class StubSewn: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var response: (status: Int, body: String) = (200, "")
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.response.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.response.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
