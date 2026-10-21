//
//  NodeScopeTests.swift
//  SewnTests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  On a shared stack every Thread node belongs to the app whose secret it
//  registered with, and every fan-out asks the registry for nodes in the
//  caller's scope. These tests pin the registry's scoped accessors, that a
//  restart of one app's Thread never evicts another app's, that a node id
//  can't be re-homed, and how Sewn picks a scope for each stack mode.
//

import Seam
import Foundation
import AII
import XCTest
@testable import Sewn

final class NodeScopeTests: XCTestCase {

    private func node(
        _ app: String?, host: String = "127.0.0.1", grpcPort: Int = 47090,
        lastSeen: Date = Date(), acceptingStorage: Bool = true
    ) -> ThreadNode {
        ThreadNode(threadId: UUID(), host: host, grpcPort: grpcPort, httpPort: grpcPort - 9,
                   lastSeen: lastSeen, acceptingStorage: acceptingStorage, app: app)
    }

    func testAScopeAdmitsItsOwnAppsNodesOnly() {
        let ambient = node("ambient")
        let craft = node("craft")
        let unowned = node(nil)

        XCTAssertTrue(NodeScope.all.admits(ambient))
        XCTAssertTrue(NodeScope.all.admits(unowned))

        XCTAssertTrue(NodeScope.app(.ambient).admits(ambient))
        XCTAssertFalse(NodeScope.app(.ambient).admits(craft))
        XCTAssertFalse(NodeScope.app(.ambient).admits(unowned), "a node of no app is no app's")

        XCTAssertFalse(NodeScope.none.admits(ambient))
        XCTAssertFalse(NodeScope.none.admits(unowned))
    }

    /// The stack's one Thread registers as the stack identity and serves every app,
    /// keeping them apart by lane — so every app's scope reaches it, and no-app's
    /// scope still reaches nothing.
    func testTheStacksThreadIsEveryAppsNode() {
        let stackThread = node(StackIdentity.stack.rawValue)
        for app in AIIApp.allCases {
            XCTAssertTrue(NodeScope.app(app).admits(stackThread), app.rawValue)
        }
        XCTAssertTrue(NodeScope.all.admits(stackThread))
        XCTAssertFalse(NodeScope.none.admits(stackThread))
    }

    func testTheAccessorsAnswerWithinTheScope() async {
        let registry = RegistryMutator.test()
        let ambient = node("ambient", grpcPort: 47090)
        let craft = node("craft", grpcPort: 48090)
        let craftFull = node("craft", grpcPort: 48091, acceptingStorage: false)
        let craftStale = node("craft", grpcPort: 48092, lastSeen: Date().addingTimeInterval(-120))
        for n in [ambient, craft, craftFull, craftStale] { await registry.registerNode(n) }

        let allActive = await registry.activeNodes(in: .all).map(\.threadId)
        XCTAssertEqual(Set(allActive), [ambient.threadId, craft.threadId, craftFull.threadId])

        let craftActive = await registry.activeNodes(in: .app(.craft)).map(\.threadId)
        XCTAssertEqual(Set(craftActive), [craft.threadId, craftFull.threadId])

        let craftStorage = await registry.availableForStorage(in: .app(.craft)).map(\.threadId)
        XCTAssertEqual(craftStorage, [craft.threadId])

        let craftAll = await registry.allNodes(in: .app(.craft)).map(\.threadId)
        XCTAssertEqual(Set(craftAll), [craft.threadId, craftFull.threadId, craftStale.threadId],
                       "allNodes keeps a node seen within five minutes, active or not")

        let veil = await registry.allNodes(in: .app(.veil))
        XCTAssertTrue(veil.isEmpty)
        let none = await registry.activeNodes(in: .none)
        XCTAssertTrue(none.isEmpty)

        let registered = await registry.registeredNode(threadId: craftStale.threadId)
        XCTAssertEqual(registered?.app, "craft", "registeredNode answers for an inactive node too")
        let unknown = await registry.registeredNode(threadId: UUID())
        XCTAssertNil(unknown)

        // Seam reads it through the protocol; its extension default knows
        // no nodes, so the witness must be the actor's own method.
        let seam: any ThreadRegistry = registry
        let throughSeam = await seam.registeredNode(threadId: craftStale.threadId)
        XCTAssertEqual(throughSeam?.threadId, craftStale.threadId, "the ThreadRegistry witness is the registry's own")
    }

    func testARestartEvictsTheSameAppsNodeAtThatAddressOnly() async {
        let registry = RegistryMutator.test()
        let ambientOld = node("ambient", grpcPort: 47090)
        let craftSameAddress = node("craft", grpcPort: 47090)
        await registry.registerNode(ambientOld)
        await registry.registerNode(craftSameAddress)

        // Ambient's Thread came back with a new id at the same host:port.
        let ambientNew = node("ambient", grpcPort: 47090)
        await registry.registerNode(ambientNew)

        let ids = Set(await registry.allNodes(in: .all).map(\.threadId))
        XCTAssertFalse(ids.contains(ambientOld.threadId), "the same app's stale node at that address is gone")
        XCTAssertTrue(ids.contains(ambientNew.threadId))
        XCTAssertTrue(ids.contains(craftSameAddress.threadId), "another app's node at that address stays")
    }

    func testANodeIdCannotBeReHomedToAnotherApp() async {
        let registry = RegistryMutator.test()
        let ambient = node("ambient", grpcPort: 47090)
        await registry.registerNode(ambient)

        let asCraft = ThreadNode(threadId: ambient.threadId, host: "127.0.0.1", grpcPort: 48090,
                                 httpPort: 48081, acceptingStorage: false, app: "craft")
        await registry.registerNode(asCraft)

        let kept = await registry.registeredNode(threadId: ambient.threadId)
        XCTAssertEqual(kept?.app, "ambient")
        XCTAssertEqual(kept?.grpcPort, 47090, "the cross-app registration changed nothing")
        XCTAssertEqual(kept?.acceptingStorage, true)
        let craft = await registry.activeNodes(in: .app(.craft))
        XCTAssertTrue(craft.isEmpty)

        // The same app re-registering its own id is an ordinary update.
        let moved = ThreadNode(threadId: ambient.threadId, host: "127.0.0.1", grpcPort: 47095,
                               httpPort: 47086, app: "ambient")
        await registry.registerNode(moved)
        let updated = await registry.registeredNode(threadId: ambient.threadId)
        XCTAssertEqual(updated?.grpcPort, 47095)
    }

    func testSewnPicksTheScopeForItsStackMode() {
        let open = SewnCore(stack: .open)
        XCTAssertEqual(open.nodeScope(for: nil), .all)
        XCTAssertEqual(open.nodeScope(for: .craft), .all, "no stack: every node is everyone's")

        let shared = SewnCore(stack: .multiApp(StackKeyring(fixed: [.ambient: "a", .craft: "b"])))
        XCTAssertEqual(shared.nodeScope(for: .ambient), .app(.ambient))
        XCTAssertEqual(shared.nodeScope(for: .craft), .app(.craft))
        XCTAssertEqual(shared.nodeScope(for: nil), .none, "a shared Sewn asked for no app reaches no Thread")
    }
}
