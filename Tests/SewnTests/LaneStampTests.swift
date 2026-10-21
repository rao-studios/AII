//
//  LaneStampTests.swift
//  SewnTests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  On a shared stack every request Sewn forwards to Thread carries the lane of
//  the app whose secret matched it — Thread trusts that stamp on the session
//  stream alone. A request with no lane is never built; off the shared stack
//  the stamp is the empty string, Thread's `unscoped`.
//

import AII
import Seam
import XCTest
@testable import Sewn

final class LaneStampTests: XCTestCase {

    private let lanes = AIILanes(lanes: [
        .ambient: AIILanes.Lane(id: LaneID(rawValue: "aaaaaaaa-0000-4000-8000-00000000000a"), derivedFrom: "t", registeredAt: Date(),
                                displayName: "Ambient", registeredBy: .app(.ambient), owner: .local),
        .craft: AIILanes.Lane(id: LaneID(rawValue: "bbbbbbbb-0000-4000-8000-00000000000b"), derivedFrom: "t", registeredAt: Date(),
                              displayName: "Craft", registeredBy: .app(.craft), owner: .local),
    ])

    private func request(app: AIIApp?) -> SewnRequest {
        SewnRequest(ownerId: "owner", group: SewnCore.Group.test(id: "g", ownerId: "owner"),
                    aggregate: nil, scope: .personal, requestID: nil, callerApp: app)
    }

    // MARK: - Which lane

    func testASharedSewnStampsTheCallersRegisteredLane() {
        let sewn = SewnCore(stack: .multiApp(StackKeyring(fixed: [.ambient: "a", .craft: "c"])), lanes: AIILaneRegistry(fixed: lanes))
        XCTAssertEqual(sewn.lane(for: .ambient), "aaaaaaaa-0000-4000-8000-00000000000a")
        XCTAssertEqual(sewn.lane(for: .craft), "bbbbbbbb-0000-4000-8000-00000000000b")
        XCTAssertNil(sewn.lane(for: .veil), "an app with no registered lane gets none")
        XCTAssertNil(sewn.lane(for: nil), "a request that lost its app gets none")
    }

    func testASharedSewnWithoutLanesStampsNothing() {
        let sewn = SewnCore(stack: .multiApp(StackKeyring(fixed: [.ambient: "a"])), lanes: nil)
        XCTAssertNil(sewn.lane(for: .ambient))
    }

    func testOffTheSharedStackThereAreNoLanes() {
        XCTAssertEqual(SewnCore(stack: .open).lane(for: nil), "")
        XCTAssertEqual(SewnCore(stack: .open).lane(for: .ambient), "")
    }

    // MARK: - Every builder carries it

    func testEveryRequestCarriesTheLane() {
        let lane = "aaaaaaaa-0000-4000-8000-00000000000a"
        let req = request(app: .ambient)
        XCTAssertEqual(ThreadFanoutRequests.search(queryText: "q", request: req, topK: 3, lane: lane)?.lane, lane)
        XCTAssertEqual(ThreadFanoutRequests.index(items: [], request: req, lane: lane)?.lane, lane)
        XCTAssertEqual(ThreadFanoutRequests.remove(documentIds: ["d"], ownerId: "owner", lane: lane)?.lane, lane)
        XCTAssertEqual(ThreadFanoutRequests.library(ownerId: "owner", lane: lane)?.lane, lane)
        XCTAssertEqual(ThreadFanoutRequests.documents(ownerId: "owner", documentIds: ["d"], lane: lane)?.lane, lane)
        XCTAssertEqual(ThreadFanoutRequests.graph(ownerId: "owner", entity: nil, query: nil, kinds: [], hops: 1, limit: 20,
                                                  includeDocuments: true, lane: lane)?.lane, lane)
        XCTAssertEqual(ThreadFanoutRequests.updateGroup(groupId: "g", ownerId: "owner", access: nil, label: "l", description: nil,
                                                        tags: nil, updateMetadata: false, lane: lane)?.lane, lane)
        XCTAssertEqual(ThreadFanoutRequests.updateDocument(documentId: "d", ownerId: "owner", access: "available", groupId: nil,
                                                           lane: lane)?.lane, lane)
        XCTAssertEqual(ThreadFanoutRequests.stats(lane: lane)?.lane, lane)
    }

    func testNoLaneBuildsNoRequest() {
        let req = request(app: nil)
        XCTAssertNil(ThreadFanoutRequests.search(queryText: "q", request: req, topK: 3, lane: nil))
        XCTAssertNil(ThreadFanoutRequests.index(items: [], request: req, lane: nil))
        XCTAssertNil(ThreadFanoutRequests.remove(documentIds: [], ownerId: "owner", lane: nil))
        XCTAssertNil(ThreadFanoutRequests.library(ownerId: "owner", lane: nil))
        XCTAssertNil(ThreadFanoutRequests.documents(ownerId: "owner", documentIds: [], lane: nil))
        XCTAssertNil(ThreadFanoutRequests.graph(ownerId: "owner", entity: nil, query: nil, kinds: [], hops: 1, limit: 20,
                                                includeDocuments: true, lane: nil))
        XCTAssertNil(ThreadFanoutRequests.updateGroup(groupId: "g", ownerId: "owner", access: nil, label: nil, description: nil,
                                                      tags: nil, updateMetadata: false, lane: nil))
        XCTAssertNil(ThreadFanoutRequests.updateDocument(documentId: "d", ownerId: "owner", access: nil, groupId: nil, lane: nil))
        XCTAssertNil(ThreadFanoutRequests.stats(lane: nil))
    }

    func testTheBuildersKeepTheWireShape() {
        var req = request(app: .ambient)
        req = SewnRequest(ownerId: "owner", group: SewnCore.Group.test(id: "g", label: "Group", ownerId: "owner"),
                          groups: [SewnCore.Group.test(id: "other", ownerId: "owner")], entities: ["Ada"],
                          aggregate: true, scope: .global, requestID: "r", callerApp: .ambient)
        let search = ThreadFanoutRequests.search(queryText: "engine", request: req, topK: 5, lane: "")
        XCTAssertEqual(search?.queryText, "engine")
        XCTAssertEqual(search?.ownerID, "owner")
        XCTAssertEqual(search?.scope, "global")
        XCTAssertEqual(search?.topK, 5)
        XCTAssertEqual(search?.groupIds, ["other", "g"])
        XCTAssertEqual(search?.aggregate, true)
        XCTAssertEqual(search?.entities, ["Ada"])

        let item = SewnCore.BatchPutItem(id: "doc", texts: ["t"], tags: ["tag"], tagsEmbedding: nil, mediaType: .image,
                                     update: nil, name: "Name", metadata: nil)
        let index = ThreadFanoutRequests.index(items: [item], request: req, lane: "")
        XCTAssertEqual(index?.groupID, "g")
        XCTAssertEqual(index?.groupLabel, "Group")
        XCTAssertEqual(index?.scope, "global")
        XCTAssertEqual(index?.items.first?.documentID, "doc")
        XCTAssertEqual(index?.items.first?.mediaType, "image")
        XCTAssertEqual(index?.items.first?.name, "Name")
        XCTAssertEqual(index?.items.first?.tags, ["tag"])
    }

    // MARK: - Stats reduce to the caller's lane

    func testStatsReduceAcrossNodesAndKeepTheLanes() {
        var node = Thread_V1_ThreadStatsResponse()
        node.documentCount = 4
        node.groupCount = 2
        node.ownerCount = 1
        var a = Thread_V1_ThreadLaneStats()
        a.lane = "a"; a.documents = 3; a.groups = 1; a.owners = 1; a.entities = 7; a.relationships = 2
        var b = Thread_V1_ThreadLaneStats()
        b.lane = "b"; b.documents = 1; b.groups = 1; b.owners = 1; b.entities = 2
        node.lanes = [a, b]
        var second = Thread_V1_ThreadStatsResponse()
        second.documentCount = 1
        second.ownerCount = 3

        let reduced = SewnStats.reduce(["n1": node, "n2": second], lane: "a", publicDocumentCount: 9, publicGroupCount: 1)
        XCTAssertEqual(reduced.publicDocumentCount, 9)
        XCTAssertEqual(reduced.publicGroupCount, 1)
        XCTAssertEqual(reduced.lane, "a")
        XCTAssertEqual(reduced.documents, 5)
        XCTAssertEqual(reduced.groups, 2)
        XCTAssertEqual(reduced.owners, 3, "owners are shared across nodes: the largest count, not a sum")
        XCTAssertEqual(reduced.lanes?.map(\.lane), ["a", "b"])
        XCTAssertEqual(reduced.lanes?.first?.entities, 7)

        let unscoped = SewnStats.reduce(["n": second], lane: "", publicDocumentCount: 0, publicGroupCount: 0)
        XCTAssertNil(unscoped.lane, "off the shared stack no lane is named")
        XCTAssertNil(unscoped.lanes)

        let encoded = try? JSONEncoder().encode(reduced)
        let json = encoded.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        for key in ["publicDocumentCount", "publicGroupCount", "lane", "documents", "groups", "owners", "lanes"] {
            XCTAssertTrue(json.contains("\"\(key)\""), "\(key) missing from \(json)")
        }
    }

    func testTheStackIdentityIsAdmittedByTheGrantedRoutesListAlone() {
        XCTAssertTrue(LocalOnlyGrant.admits(method: .get, endpointPath: "/v1/threads"))
        XCTAssertTrue(LocalOnlyGrant.admits(method: .get, endpointPath: "/v1/stats"))
        XCTAssertFalse(LocalOnlyGrant.admits(method: .post, endpointPath: "/v1/stats"))
    }
}
