//
//  AIIBusyTests.swift
//  AIITests
//
//  Created by Ritesh Pakala on 11/07/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  Busy marks: an app generating on the GPU holds the stack's background model work off, a mark
//  renews without losing when it began, and a dead or expired mark never holds anything.
//

import Foundation
import XCTest
@testable import AII

final class AIIBusyTests: XCTestCase {
    func testAMarkIsLiveUntilReleasedAndKeepsItsStartOnRenewal() throws {
        let test = TestHome()
        let busy = AIIBusy(home: test.home)
        XCTAssertTrue(busy.live().isEmpty, "nothing marked: nothing waits")

        let start = Date()
        try busy.hold(for: .craft, now: start)
        try busy.hold(for: .craft, now: start.addingTimeInterval(60))
        let marks = busy.live(now: start.addingTimeInterval(61))
        XCTAssertEqual(marks.count, 1, "a renewal is the same mark")
        XCTAssertEqual(marks.first?.since.timeIntervalSince1970 ?? 0, start.timeIntervalSince1970, accuracy: 1, "whole seconds on disk")
        XCTAssertEqual(busy.apps(now: start.addingTimeInterval(61)), [.craft])
        XCTAssertEqual(test.mode(test.home.aiiBusyMark(for: .craft, pid: ProcessProbe.current.pid)), 0o600)

        busy.release(for: .craft)
        XCTAssertTrue(busy.live(now: start.addingTimeInterval(62)).isEmpty)
    }

    func testAnExpiredMarkHoldsNothingAndIsSwept() throws {
        let test = TestHome()
        let busy = AIIBusy(home: test.home)
        let start = Date()
        try busy.hold(for: .craft, lifetime: 30, now: start)
        XCTAssertEqual(busy.live(now: start.addingTimeInterval(29)).count, 1)
        XCTAssertTrue(busy.live(now: start.addingTimeInterval(31)).isEmpty, "a stuck app can't hold the readings off for ever")
        let left = try FileManager.default.contentsOfDirectory(atPath: PrivateFile.path(test.home.aiiBusyDirectory))
        XCTAssertTrue(left.isEmpty, "the expired mark is removed")
    }

    func testADeadProcessesMarkHoldsNothing() throws {
        let test = TestHome()
        let busy = AIIBusy(home: test.home)
        // A pid that is running but started at another time is a recycled pid: not the marker.
        let impostor = ProcessStamp(pid: ProcessProbe.current.pid, processStart: 1)
        try busy.hold(for: .veil, process: impostor)
        try busy.hold(for: .craft)
        XCTAssertEqual(busy.apps(), [.craft], "only the running marker counts")
    }

    func testEachProcessHasItsOwnMark() throws {
        let test = TestHome()
        let busy = AIIBusy(home: test.home)
        let other = ProcessStamp(pid: getppid(), processStart: ProcessProbe.startTime(of: getppid()))
        try busy.hold(for: .craft)
        try busy.hold(for: .craft, process: other)
        XCTAssertEqual(busy.live().count, 2, "Craft's CLI and Craft.app mark separately")
        busy.release(for: .craft)
        XCTAssertEqual(busy.live().map(\.process), [other], "releasing one leaves the other")
    }
}
