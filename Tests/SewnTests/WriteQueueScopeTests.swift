//
//  WriteQueueScopeTests.swift
//  SewnTests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  The write queue merges consecutive puts into one batch, indexed as the
//  first put's request. On a shared stack that request's caller app picks
//  the Thread, so two puts for different apps must never share a batch —
//  even when owner and group agree.
//

import AII
import XCTest
@testable import Sewn

final class WriteQueueScopeTests: XCTestCase {

    private func request(owner: String = "owner", group: String? = "g1", app: AIIApp?) -> SewnRequest {
        SewnRequest(ownerId: owner, group: group.map { SewnCore.Group.test(id: $0, ownerId: owner) },
                    aggregate: nil, scope: .personal, requestID: nil, callerApp: app)
    }

    func testPutsForTheSameOwnerGroupAndAppCoalesce() {
        XCTAssertTrue(SewnCore.canCoalesce(request(app: .ambient), into: request(app: .ambient)))
        XCTAssertTrue(SewnCore.canCoalesce(request(app: nil), into: request(app: nil)),
                      "an open or one-app Sewn has no app and coalesces as before")
        XCTAssertTrue(SewnCore.canCoalesce(request(group: nil, app: nil), into: request(group: nil, app: nil)))
    }

    func testPutsDifferingOnlyByCallerAppDoNotCoalesce() {
        XCTAssertFalse(SewnCore.canCoalesce(request(app: .craft), into: request(app: .ambient)))
        XCTAssertFalse(SewnCore.canCoalesce(request(app: nil), into: request(app: .ambient)),
                       "a put that lost its app rides no other app's batch")
        XCTAssertFalse(SewnCore.canCoalesce(request(app: .ambient), into: request(app: nil)))
    }

    func testOwnerAndGroupStillGate() {
        XCTAssertFalse(SewnCore.canCoalesce(request(owner: "other", app: .ambient), into: request(app: .ambient)))
        XCTAssertFalse(SewnCore.canCoalesce(request(group: "g2", app: .ambient), into: request(app: .ambient)))
        XCTAssertFalse(SewnCore.canCoalesce(request(group: nil, app: .ambient), into: request(app: .ambient)))
    }
}
