//
//  LaneResolverTests.swift
//  ThreadTests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  Who is calling the one Thread, and which lane that puts them in. A lane is
//  never trusted from a client: a direct RPC's lane comes from its secret, a
//  session request's from the lane Sewn stamped, and anything else is refused.
//

import AII
import GRPCCore
import XCTest
@testable import Thread

final class LaneResolverTests: XCTestCase {

    func testAThreadWithNoLanesScopesNothing() throws {
        let open = LaneResolver.unscoped
        XCTAssertFalse(open.isMultiApp)
        XCTAssertEqual(try open.scope(for: .metadata([:])), .lane(.unscoped))
        XCTAssertEqual(try open.scope(for: .metadata(.presenting("anything"))), .lane(.unscoped))
        XCTAssertEqual(try open.scope(for: .trusted(lane: "")), .lane(.unscoped))
        XCTAssertEqual(try open.scope(for: .trusted(lane: "whatever")), .lane(.unscoped), "a stamp means nothing without lanes")
        XCTAssertEqual(try open.scope(identity: nil), .lane(.unscoped))
        XCTAssertEqual(try open.scope(identity: .app(.craft)), .lane(.unscoped))
        XCTAssertEqual(try open.lane(for: .veil), .unscoped)
    }

    func testADirectCallIsScopedByItsSecret() throws {
        let resolver = LaneResolver.test
        XCTAssertTrue(resolver.isMultiApp)
        XCTAssertEqual(try resolver.scope(for: .metadata(.presenting("ambient-secret"))), .lane(.a))
        XCTAssertEqual(try resolver.scope(for: .metadata(.presenting("craft-secret"))), .lane(.b))
        XCTAssertEqual(try resolver.scope(for: .metadata(.presenting("aii-secret"))), .all)
        XCTAssertThrowsError(try resolver.scope(for: .metadata(.presenting("stranger")))) { error in
            XCTAssertEqual((error as? RPCError)?.code, .unauthenticated)
        }
        XCTAssertThrowsError(try resolver.scope(for: .metadata([:]))) { error in
            XCTAssertEqual((error as? RPCError)?.code, .unauthenticated)
        }
    }

    func testASessionRequestIsScopedByTheStampedLane() throws {
        let resolver = LaneResolver.test
        XCTAssertEqual(try resolver.scope(for: .trusted(lane: LaneID.a.rawValue)), .lane(.a))
        XCTAssertEqual(try resolver.scope(for: .trusted(lane: LaneID.b.rawValue.uppercased())), .lane(.b),
                       "lane ids compare case-insensitively")
        XCTAssertThrowsError(try resolver.scope(for: .trusted(lane: ""))) { error in
            XCTAssertEqual((error as? RPCError)?.code, .failedPrecondition, "an unstamped request fails closed")
        }
        XCTAssertThrowsError(try resolver.scope(for: .trusted(lane: "11111111-2222-4333-8444-555555555555"))) { error in
            XCTAssertEqual((error as? RPCError)?.code, .failedPrecondition, "an unregistered lane fails closed")
        }
    }

    func testAnHTTPIdentityMapsToItsLane() throws {
        let resolver = LaneResolver.test
        XCTAssertEqual(try resolver.scope(identity: .app(.ambient)), .lane(.a))
        XCTAssertEqual(try resolver.scope(identity: .app(.craft)), .lane(.b))
        XCTAssertEqual(try resolver.scope(identity: .stack), .all)
        XCTAssertEqual(try resolver.lane(for: .ambient), .a)
    }

    /// An app that wrote its secret and stopped before its lane, or registered after this
    /// Thread started, gets the lane any later call derives — never a misfiled one.
    func testAnAdmittedAppWithoutALaneGetsOneRegistered() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("thread-lanes-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = AIIHome(root: root)
        try AIILanes.ensure(home: home, apps: [.ambient])
        // No reload throttle: the keyring's own (one read per miss every 2 s) is AIITests'.
        let keyring = StackKeyring(home: home, minimumReloadInterval: 0)
        let resolver = LaneResolver(stack: .multiApp(keyring), lanes: AIILaneRegistry(home: home, minimumReloadInterval: 0))

        let secret = try home.ensureSecret(for: AIIApp("notes"))
        let key = try XCTUnwrap(try AIIDeviceKey.load(home: home))
        let lane = AIILanes.derive(app: "notes", from: key)
        XCTAssertEqual(try resolver.scope(for: .metadata(.presenting(secret))), .lane(lane))
        XCTAssertEqual(try AIILanes.load(home: home)?.id(for: "notes"), lane, "written to lanes.json")
        XCTAssertEqual(try resolver.scope(for: .trusted(lane: lane.rawValue)), .lane(lane), "Sewn's stamp is now known")
        XCTAssertEqual(resolver.appName(for: lane), "Notes")
    }

    func testTheStackIdentityReadsEverythingAndWritesNothing() throws {
        let resolver = LaneResolver.test
        XCTAssertNil(LaneScope.all.filter, "no cut: every lane")
        XCTAssertNil(LaneScope.all.writeLane)
        XCTAssertThrowsError(try resolver.writeLane(.all)) { error in
            XCTAssertEqual((error as? RPCError)?.code, .failedPrecondition)
        }
        XCTAssertEqual(try resolver.writeLane(.lane(.a)), .a)
        XCTAssertEqual(try resolver.writeLane(.lane(.unscoped)), .unscoped, "no lanes: writes file under none")
        XCTAssertEqual(LaneScope.lane(.a).filter, .a)
        XCTAssertNil(LaneScope.lane(.unscoped).filter)
        XCTAssertTrue(LaneScope.all.admits(.a))
        XCTAssertTrue(LaneScope.lane(.a).admits(.a))
        XCTAssertFalse(LaneScope.lane(.a).admits(.b))
        XCTAssertTrue(LaneScope.lane(.unscoped).admits(.b))
    }

    func testLanesAreNamedByTheirApp() {
        let resolver = LaneResolver.test
        XCTAssertEqual(resolver.appName(for: .a), "Ambient")
        XCTAssertEqual(resolver.appName(for: .b), "Craft")
        XCTAssertEqual(resolver.appName(for: .unscoped), "no lane")
        XCTAssertEqual(resolver.appName(for: LaneID(rawValue: "unknown")), "unknown")
    }

    func testTheRegistryKeepsLanesAcrossACodingRoundTrip() throws {
        var registry = ThreadRegistry()
        registry.applyRegister(documentId: "d1", ownerId: "o", group: .test(id: "g1"), lane: .a)
        registry.applyRegister(documentId: "d2", ownerId: "o", group: nil, lane: .b)
        let data = try PropertyListEncoder().encode(registry)
        let decoded = try PropertyListDecoder().decode(ThreadRegistry.self, from: data)
        XCTAssertEqual(decoded.documentLanes, ["d1": .a, "d2": .b])
        XCTAssertEqual(decoded.laneDocuments[.a], ["d1"])
        XCTAssertEqual(decoded.laneDocuments[.b], ["d2"])
        XCTAssertEqual(decoded.groupLanes["g1"], .a)
        XCTAssertEqual(decoded.laneGroups[.a], ["g1"])
    }

    func testADocumentHasOneLaneForLife() {
        var registry = ThreadRegistry()
        registry.applyRegister(documentId: "d", ownerId: "o", group: .test(id: "g"), lane: .a)
        XCTAssertTrue(registry.admits(documentId: "d", lane: .a))
        XCTAssertFalse(registry.admits(documentId: "d", lane: .b))
        XCTAssertTrue(registry.admits(documentId: "d", lane: .unscoped), "a Thread with no lanes sees everything")
        XCTAssertTrue(registry.admits(documentId: "new", lane: .b), "an unfiled id is anyone's")
        XCTAssertFalse(registry.linkOwner(documentId: "d", ownerId: "other", group: nil, lane: .b))
        XCTAssertFalse(registry.isOwnerLinked("d", ownerId: "other"), "a refused link writes nothing")
        XCTAssertTrue(registry.linkOwner(documentId: "d", ownerId: "other", group: nil, lane: .a))

        // A group created in one lane is not filed into from another: the document
        // lands without a group rather than in it.
        registry.applyRegister(documentId: "e", ownerId: "o", group: .test(id: "g"), lane: .b)
        XCTAssertEqual(registry.lane(ofGroup: "g"), .a)
        XCTAssertFalse(registry.groups["g"]?.contains("e") ?? false)
        XCTAssertEqual(registry.lane(of: "e"), .b)
        XCTAssertEqual(registry.foreignLanes(of: ["d", "e"], outside: .a), [.b])
        XCTAssertEqual(registry.foreignLanes(of: ["d"], outside: .a), [])
        XCTAssertEqual(registry.foreignLanes(of: ["d", "e"], outside: .unscoped), [], "no lane, no rule")

        // The last owner gone takes the lane entry with it.
        registry.remove(documentId: "d", group: nil, owner: .init(id: "o"))
        XCTAssertEqual(registry.lane(of: "d"), .a, "a co-owner still holds it")
        registry.remove(documentId: "d", group: nil, owner: .init(id: "other"))
        XCTAssertEqual(registry.lane(of: "d"), .unscoped)
        XCTAssertNil(registry.laneDocuments[.a])
    }
}

final class ExtractionRouteTests: XCTestCase {
    func testTheRouteIsDecidedByWhatTheDocumentIs() {
        XCTAssertEqual(ExtractionRoute.decide(mediaType: .text, hasCallerEntities: false), .llm)
        XCTAssertEqual(ExtractionRoute.decide(mediaType: .code, hasCallerEntities: false), .identifiers)
        XCTAssertEqual(ExtractionRoute.decide(mediaType: .image, hasCallerEntities: false), .none)
        for mediaType in [MediaType.text, .code, .image] {
            XCTAssertEqual(ExtractionRoute.decide(mediaType: mediaType, hasCallerEntities: true), .none,
                           "a caller that said what the document is about is believed")
        }
    }

    func testProseGetsKeywordsPendingTheLLM() {
        let (entities, needsExtraction) = ExtractionRoute.llm.entities(
            for: ["Ada Lovelace worked with Charles Babbage on the analytical engine."], cap: 12)
        XCTAssertTrue(needsExtraction)
        XCTAssertFalse(entities.isEmpty)
        XCTAssertTrue(entities.allSatisfy { $0.kind == "concept" })
    }

    func testCodeGetsItsIdentifiersAndNoLLM() {
        let card = "// craft:fn Session.send(_:)\npublic func sendMessage(_ input: String) -> ReplyToken {}"
        let (entities, needsExtraction) = ExtractionRoute.identifiers.entities(for: [card], cap: 12)
        XCTAssertFalse(needsExtraction, "the LLM never reads code")
        XCTAssertFalse(entities.isEmpty)
        XCTAssertTrue(entities.allSatisfy { $0.name.hasPrefix(CodeIdentifierExtractor.namespace) }, "\(entities.map(\.name))")
        XCTAssertTrue(entities.contains { $0.name == "sym:sendMessage" } || entities.contains { $0.name == "sym:ReplyToken" },
                      "\(entities.map(\.name))")
        let capped = ExtractionRoute.identifiers.entities(for: [card], cap: 1).entities
        XCTAssertEqual(capped.count, 1)
    }

    func testAPictureGetsNothing() {
        let (entities, needsExtraction) = ExtractionRoute.none.entities(for: ["a caption, if any"], cap: 12)
        XCTAssertTrue(entities.isEmpty)
        XCTAssertFalse(needsExtraction)
    }
}
