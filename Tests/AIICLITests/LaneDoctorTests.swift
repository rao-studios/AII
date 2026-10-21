//
//  LaneDoctorTests.swift
//  AIICLITests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  The lane doctor, layer by layer: on a healthy lane every layer passes; breaking one
//  layer makes that layer fail with its fix, and the walk stops where nothing above the
//  break can work. `checks` is pure over what `gather` saw, so each break is a value.
//

import AII
import Foundation
import XCTest
@testable import AIICLI

final class LaneDoctorTests: XCTestCase {

    private func register(_ scratch: ScratchHome) throws -> AIILanes.Lane {
        try scratch.home.register("notes", displayName: "Notes")
    }

    /// What a healthy notes lane looks like to the doctor, under `owner`.
    private func healthy(_ lane: AIILanes.Lane, owner: AIIOwner = .app("notes")) -> LaneDoctor.Observations {
        let stats = AIIStats(lane: lane.id, documents: 3, groups: 2, owners: 1, entities: 5, relationships: 1)
        let inspection = AIILaneInspection(
            owner: owner,
            groups: [.init(id: "notes-notes", label: "Notes", documents: 2),
                     .init(id: "notes-memory-\(owner)", label: "Memory", documents: 1)],
            sample: [.init(documentID: "notes/note/n1", isRecord: true, recordApp: "notes", kind: "note", idMatches: true),
                     .init(documentID: "notes/note/n2", isRecord: true, recordApp: "notes", kind: "note", idMatches: true),
                     .init(documentID: "notes/memory/m1", isRecord: true, recordApp: "notes", kind: "memory", idMatches: true)],
            sampledAll: true)
        return LaneDoctor.Observations(sewn: .ours(contract: 1), thread: .ours(contract: 1), stats: .success(stats),
                                       inspection: .success(inspection), logs: [])
    }

    private func inspect(_ observed: inout LaneDoctor.Observations, _ change: (inout AIILaneInspection) -> Void) {
        guard case .success(var inspection)? = observed.inspection else { return XCTFail("no inspection") }
        change(&inspection)
        observed.inspection = .success(inspection)
    }

    private func failing(_ checks: [DoctorCheck]) -> [String] { checks.filter { !$0.ok }.map(\.name) }

    func testAHealthyLanePassesEveryLayer() throws {
        let scratch = ScratchHome()
        let checks = LaneDoctor.checks("notes", home: scratch.home, observed: healthy(try register(scratch)))
        XCTAssertEqual(checks.map(\.name), ["manifest", "secret", "lane id", "admission", "thread", "groups", "records", "owner", "logs"])
        XCTAssertEqual(failing(checks), [], checks.map(\.line).joined(separator: "\n"))
        XCTAssertTrue(checks[7].detail.contains("memory in notes-memory-local-notes"), checks[7].detail)
    }

    func testTheManifest() throws {
        let scratch = ScratchHome()
        let lane = try register(scratch)
        try scratch.home.register("other")
        try AIILanes.remove(home: scratch.home, app: "notes")
        var checks = LaneDoctor.checks("notes", home: scratch.home, observed: healthy(lane))
        XCTAssertEqual(checks.map(\.name), ["manifest"], "nothing above it can work")
        XCTAssertEqual(checks.first?.fix, "aii lanes add notes")

        try scratch.home.register("notes")
        let file = try String(contentsOf: scratch.home.lanesFile, encoding: .utf8)
        try PrivateFile.writeAtomically(Data(file.replacingOccurrences(of: "local-notes", with: "local-craft").utf8),
                                        to: scratch.home.lanesFile, mode: 0o600)
        checks = LaneDoctor.checks("notes", home: scratch.home, observed: healthy(lane))
        XCTAssertEqual(failing(checks), ["manifest"])
        XCTAssertEqual(checks.first?.fix, "aii lanes owner notes aii-local")
    }

    func testTheSecret() throws {
        let scratch = ScratchHome()
        let lane = try register(scratch)
        try FileManager.default.removeItem(at: scratch.home.secretFile(for: AIIApp("notes")))
        let checks = LaneDoctor.checks("notes", home: scratch.home, observed: healthy(lane))
        XCTAssertEqual(failing(checks), ["secret"])
        XCTAssertEqual(checks.last?.name, "secret", "nothing above it can work")
    }

    func testAdmission() throws {
        let scratch = ScratchHome()
        var observed = healthy(try register(scratch))
        observed.thread = .stale
        var checks = LaneDoctor.checks("notes", home: scratch.home, observed: observed)
        XCTAssertEqual(failing(checks), ["admission"])
        XCTAssertTrue(checks.last?.fix?.contains("two seconds") == true, "a server reads a new secret on its next reload")
        observed.thread = .down
        checks = LaneDoctor.checks("notes", home: scratch.home, observed: observed)
        XCTAssertEqual(checks.last?.fix, "aii start")
    }

    func testThreadFilingTheAppInAnotherLane() throws {
        let scratch = ScratchHome()
        var observed = healthy(try register(scratch))
        observed.stats = .success(AIIStats(lane: LaneID("ffffffff-0000-4000-8000-00000000000f"), documents: 0, groups: 0,
                                           owners: 0, entities: 0, relationships: 0))
        XCTAssertEqual(failing(LaneDoctor.checks("notes", home: scratch.home, observed: observed)), ["thread"])
    }

    func testGroups() throws {
        let scratch = ScratchHome()
        let lane = try register(scratch)
        var observed = healthy(lane)
        inspect(&observed) { $0.groups.append(.init(id: "standups", label: "Stand-ups", documents: 0)) }
        var checks = LaneDoctor.checks("notes", home: scratch.home, observed: observed)
        XCTAssertEqual(failing(checks), ["groups"])
        XCTAssertTrue(checks.first { $0.name == "groups" }?.detail.contains("standups") == true)

        observed = healthy(lane)
        inspect(&observed) { $0.groups.removeLast() }
        checks = LaneDoctor.checks("notes", home: scratch.home, observed: observed)
        XCTAssertEqual(failing(checks), ["groups"], "a document in no group")
        XCTAssertEqual(checks.first { $0.name == "groups" }?.detail, "1 of local-notes's documents have no group")
    }

    func testADocumentOutsideTheSchema() throws {
        let scratch = ScratchHome()
        var observed = healthy(try register(scratch))
        inspect(&observed) {
            $0.sample.append(.init(documentID: "hand-filed", isRecord: false, idMatches: false))
            $0.groups[0].documents += 1
        }
        let checks = LaneDoctor.checks("notes", home: scratch.home, observed: observed)
        XCTAssertEqual(failing(checks), ["records"])
        XCTAssertTrue(checks.first { $0.name == "records" }?.detail.contains("hand-filed") == true)
    }

    func testAnOwnerSwitchedWithoutFilingAgain() throws {
        let scratch = ScratchHome()
        let lane = try register(scratch)
        try scratch.home.setOwner(.local, for: "notes")
        var observed = healthy(lane, owner: .local)
        inspect(&observed) {
            $0.groups = []
            $0.sample = []
        }
        let checks = LaneDoctor.checks("notes", home: scratch.home, observed: observed)
        XCTAssertEqual(failing(checks), ["owner"])
        XCTAssertTrue(checks.first { $0.name == "owner" }?.detail.contains("none under aii-local") == true)
    }

    func testTheLogs() throws {
        let scratch = ScratchHome()
        var observed = healthy(try register(scratch))
        observed.logs = ["thread: refused notes: group notes-x belongs to another owner"]
        XCTAssertEqual(failing(LaneDoctor.checks("notes", home: scratch.home, observed: observed)), ["logs"])

        let log = try scratch.file("sewn.log", contents: "ok notes\nERROR notes: dropped a write\nerror craft: x\nnotes refused: y\n",
                                   mode: 0o600)
        XCTAssertEqual(LaneDoctor.recentProblems(naming: ["notes"], in: [(log, nil)]),
                       ["ERROR notes: dropped a write", "notes refused: y"])

        let stamped = try scratch.file("thread.log", contents: """
            2026-10-16T16:10:08-0700 warning thread: extraction failed for notes/note/n1
            2026-10-16T16:12:30-0700 warning thread: refused notes: group notes-x belongs to another owner
            """, mode: 0o600)
        let restarted = try XCTUnwrap(LaneDoctor.stamp("2026-10-16T16:12:24-0700 info thread: up"))
        XCTAssertEqual(LaneDoctor.recentProblems(naming: ["notes"], in: [(stamped, restarted)]).count, 1,
                       "a line from before the server started is not recent")
    }
}
