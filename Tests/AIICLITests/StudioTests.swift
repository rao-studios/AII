//
//  StudioTests.swift
//  AIICLITests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  The studio as pure functions: each screen draws from a fixed state, the empty home
//  included; each key asks for the job its CLI verb does; one action at a time; a lane's
//  owner switches only with y; the lane doctor runs in a pane; and a lane is removed only
//  once its name is typed.
//

import AII
import Foundation
import XCTest
@testable import AIICLI

final class StudioTests: XCTestCase {

    private func draw(_ state: StudioState, width: Int = 110, height: Int = 30) -> String {
        let capabilities = Capabilities(isTTY: true, colorDepth: .ansi256)
        var frame = Frame(canvas: Canvas(size: Size(width: width, height: height)),
                          palette: Palette(for: capabilities, environment: [:]), glyphs: .unicode)
        StudioApp.render(state, &frame)
        return frame.canvas.lines.joined(separator: "\n")
    }

    private func press(_ character: Character, _ state: inout StudioState) -> [StudioJob] {
        StudioApp.handle(.key(.char(character)), state: &state)
    }

    private func press(_ key: Key, _ state: inout StudioState) -> [StudioJob] {
        StudioApp.handle(.key(KeyEvent(key)), state: &state)
    }

    private func type(_ text: String, _ state: inout StudioState) {
        for character in text { _ = press(character, &state) }
    }

    private func report(installed: Bool, up: Bool) -> StatusReport {
        let install = installed ? StatusReport.Install(
            summary: "", source: "local", installedBy: "aii", appVersion: "AII 256e699a1c0f", contract: 1, sha256: "ab",
            installedAt: Date(timeIntervalSince1970: 1_792_000_000), checkout: "/src/AII", commit: "256e699a1c0f",
            configuration: "release") : nil
        let servers = ["sewn", "thread"].map { role in
            StatusReport.Server(role: role, state: up ? "up" : "down", healthy: up, detail: nil, pid: up ? 4123 : nil,
                                http: role == "sewn" ? 47080 : 47081, grpc: role == "sewn" ? 47091 : 47090,
                                verified: up, contract: 1, binary: nil, launchedBy: nil, startedAt: nil, embedder: nil)
        }
        return StatusReport(home: "/tmp/rao", layout: installed ? 1 : nil, provisionedBy: installed ? "Ambient" : nil,
                            install: install, contract: 1, servers: servers, holders: [], lanes: ["ambient", "notes"], models: nil)
    }

    // MARK: - Screens

    func testIndexShowsTheStatusRowsAndTheKeysThatActOnThem() {
        var state = StudioState()
        state.report = report(installed: true, up: true)
        let screen = draw(state)
        XCTAssertTrue(screen.contains("1 Index"), screen)
        XCTAssertTrue(screen.contains("Your build @ 256e699a1c0f from /src/AII"), screen)
        XCTAssertTrue(screen.contains("Sewn      ✓ up · pid 4123"), screen)
        XCTAssertTrue(screen.contains("[i] install your build"), screen)
        XCTAssertTrue(screen.contains("[u] update"), screen)
        XCTAssertTrue(screen.contains("[s] stop"), screen)
    }

    func testAnEmptyHomeIsAStateNotAnError() {
        var state = StudioState()
        state.report = report(installed: false, up: false)
        let screen = draw(state)
        XCTAssertTrue(screen.contains("Nothing is installed. Press i to build AII from this checkout"), screen)
        XCTAssertTrue(screen.contains("[s] start"), screen)
        XCTAssertFalse(screen.contains("[u] update"), "nothing of yours to update")
        XCTAssertFalse(screen.contains("aii: "), "no error shown")
    }

    func testLanesModelsLogsAndDoctorDraw() {
        var state = StudioState()
        state.screen = .lanes
        state.lanesRead = true
        state.lanes = [LaneRow(name: "notes", displayName: "My Notes", lane: "4a5b6c7d-0000-4000-8000-000000000001",
                               owner: "local-notes", secret: true, documents: 3)]
        var screen = draw(state)
        XCTAssertTrue(screen.contains("notes") && screen.contains("My Notes") && screen.contains("4a5b6c7d"), screen)
        XCTAssertTrue(screen.contains("Owner") && screen.contains("local-notes"), screen)
        XCTAssertTrue(screen.contains("[o] owner") && screen.contains("[d] doctor"), "the footer names both keys: \(screen)")
        XCTAssertTrue(screen.contains("swift run --package-path Examples/Notes"), screen)

        state.screen = .models
        state.modelsProblem = "Sewn is down"
        screen = draw(state)
        XCTAssertTrue(screen.contains("generalStandard") && screen.contains("Sewn is down"), screen)

        state.screen = .logs
        state.logLines[.sewn] = ["Sewn listening on 47080"]
        screen = draw(state)
        XCTAssertTrue(screen.contains("Sewn listening on 47080"), screen)

        state.screen = .doctor
        state.doctorRan = true
        state.checks = [.pass("home", "~/.rao · layout 1"), .fail("install", "nothing installed", fix: "aii install")]
        screen = draw(state)
        XCTAssertTrue(screen.contains("✓ home") && screen.contains("→ aii install") && screen.contains("1 check failed"), screen)
    }

    // MARK: - Keys

    func testEachKeyAsksForItsVerb() {
        var state = StudioState()
        state.report = report(installed: true, up: false)
        XCTAssertEqual(press("i", &state), [.install])
        XCTAssertEqual(press("u", &state), [.update])
        XCTAssertEqual(press("s", &state), [.start])
        XCTAssertEqual(press("r", &state), [.restart])
        state.report = report(installed: true, up: true)
        XCTAssertEqual(press("s", &state), [.stop], "up: s stops")

        XCTAssertEqual(press("2", &state), [.lanes])
        XCTAssertEqual(state.screen, .lanes)
        XCTAssertEqual(press("3", &state), [.models])
        XCTAssertEqual(press("p", &state), [.pull(.embedding)])
        XCTAssertEqual(press("4", &state), [.logs(.sewn)])
        XCTAssertEqual(press(.tab, &state), [.logs(.thread)])
        XCTAssertEqual(press("5", &state), [.doctor])
        XCTAssertEqual(press("r", &state), [.doctor])
        XCTAssertEqual(press("q", &state), [])
        XCTAssertEqual(state.quitCode, 0)
    }

    func testOneActionAtATime() {
        var state = StudioState()
        state.report = report(installed: true, up: false)
        _ = StudioApp.handle(.message(.busy("installing your build")), state: &state)
        XCTAssertEqual(press("s", &state), [])
        XCTAssertEqual(state.message, "one thing at a time: installing your build is still running")
        XCTAssertEqual(press("2", &state), [.lanes], "reading still works")
        _ = StudioApp.handle(.message(.done("installed")), state: &state)
        XCTAssertNil(state.busy)
    }

    func testAddingALaneAsksTheNameThenTheDisplayName() {
        var state = StudioState()
        state.screen = .lanes
        _ = press("a", &state)
        type("Not An App", &state)
        _ = press(.enter, &state)
        guard case .laneName(_, let problem)? = state.prompt else { return XCTFail("still asking the name") }
        XCTAssertNotNil(problem)
        _ = press(.escape, &state)
        XCTAssertNil(state.prompt)

        _ = press("a", &state)
        type("notes", &state)
        _ = press(.enter, &state)
        guard case .laneDisplay(let name, _)? = state.prompt else { return XCTFail("asking the display name") }
        XCTAssertEqual(name, "notes")
        for _ in 0..<5 { _ = press(.backspace, &state) }
        type("My Notes", &state)
        XCTAssertEqual(press(.enter, &state), [.addLane(name: "notes", displayName: "My Notes")])
        XCTAssertNil(state.prompt)
    }

    func testALaneIsRemovedOnlyOnceItsNameIsTyped() {
        var state = StudioState()
        state.screen = .lanes
        state.lanesRead = true
        state.lanes = [LaneRow(name: "notes", displayName: "Notes", lane: "x", secret: true)]
        _ = press("x", &state)
        type("note", &state)
        XCTAssertEqual(press(.enter, &state), [], "not the name")
        guard case .removeLane(_, _, let problem)? = state.prompt else { return XCTFail("still asking") }
        XCTAssertEqual(problem, "type notes to remove it")
        type("s", &state)
        XCTAssertEqual(press(.enter, &state), [.removeLane("notes")])
    }

    func testALanesOwnerSwitchesOnlyWithY() {
        var state = StudioState()
        state.screen = .lanes
        state.lanesRead = true
        state.lanes = [LaneRow(name: "notes", displayName: "Notes", lane: "x", owner: "local-notes", secret: true)]
        _ = press("o", &state)
        XCTAssertEqual(state.prompt, .laneOwner(name: "notes", to: "aii-local"))
        XCTAssertTrue(draw(state).contains("Switch notes's owner to aii-local?"), draw(state))
        XCTAssertEqual(press("n", &state), [])
        XCTAssertNil(state.prompt)
        _ = press("o", &state)
        XCTAssertEqual(press("y", &state), [.setLaneOwner(name: "notes", owner: "aii-local")])
        state.lanes[0].owner = "aii-local"
        _ = press("o", &state)
        XCTAssertEqual(state.prompt, .laneOwner(name: "notes", to: "local-notes"), "and back")
    }

    func testTheLaneDoctorRunsInAPane() {
        var state = StudioState()
        state.screen = .lanes
        state.lanesRead = true
        state.lanes = [LaneRow(name: "notes", displayName: "Notes", lane: "x", owner: "local-notes", secret: true)]
        XCTAssertEqual(press("d", &state), [.laneDoctor("notes")])
        XCTAssertTrue(draw(state).contains("walking notes down the stack"), draw(state))
        let checks: [DoctorCheck] = [.pass("manifest", "Notes · owner local-notes"),
                                     .fail("admission", "Thread isn't running", fix: "aii start")]
        _ = StudioApp.handle(.message(.laneDoctor("notes", checks)), state: &state)
        let screen = draw(state)
        XCTAssertTrue(screen.contains("notes · lane doctor") && screen.contains("✗ admission") && screen.contains("→ aii start"), screen)
        XCTAssertTrue(screen.contains("fix admission first"), screen)
        XCTAssertEqual(press("j", &state), [], "any key closes it")
        XCTAssertNil(state.laneDoctor)
        _ = StudioApp.handle(.message(.laneDoctor("notes", checks)), state: &state)
        XCTAssertNil(state.laneDoctor, "a pane closed before its checks came back stays closed")
    }

    func testAModelIsRemovedOnlyWithY() {
        var state = StudioState()
        state.screen = .models
        _ = press("x", &state)
        XCTAssertEqual(state.prompt, .removeModel(.embedding))
        XCTAssertEqual(press("n", &state), [])
        XCTAssertNil(state.prompt)
        _ = press("x", &state)
        XCTAssertEqual(press("y", &state), [.removeModel(.embedding)])
    }
}
