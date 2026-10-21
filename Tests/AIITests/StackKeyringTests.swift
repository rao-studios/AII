//
//  StackKeyringTests.swift
//  AIITests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation
import XCTest
@testable import AII

final class StackKeyringTests: XCTestCase {

    func testItResolvesEachIdentityBySecret() throws {
        let test = TestHome()
        let secrets = try test.home.provision(by: .ambient)
        let ring = StackKeyring(home: test.home)
        for app in AIIApp.allCases {
            XCTAssertEqual(ring.app(forPresented: secrets[.app(app)]), app)
            XCTAssertEqual(ring.identity(forPresented: secrets[.app(app)]), .app(app))
            XCTAssertEqual(ring.secret(for: app), secrets[.app(app)])
        }
        XCTAssertEqual(ring.identity(forPresented: secrets[.stack]), .stack)
        XCTAssertNil(ring.app(forPresented: secrets[.stack]), "the stack identity is not an app")
        XCTAssertEqual(ring.secret(for: .stack), secrets[.stack])
        XCTAssertNil(ring.app(forPresented: nil))
        XCTAssertNil(ring.app(forPresented: ""))
        XCTAssertNil(ring.identity(forPresented: StackSecret.generate()))
        XCTAssertEqual(ring.provisionedIdentities, [.stack, .app(.ambient), .app(.craft), .app(.veil)], "by name, the stack first")
    }

    func testASecretPublishedLaterIsPickedUpOnAMiss() throws {
        let test = TestHome()
        _ = try test.home.ensureSecret(for: .ambient)
        let clock = Clock(Date())
        let ring = StackKeyring(home: test.home, minimumReloadInterval: 2, now: { clock.now })
        XCTAssertEqual(ring.provisionedApps, [.ambient])

        let craft = try test.home.ensureSecret(for: .craft)
        XCTAssertNil(ring.app(forPresented: craft), "within the throttle: no reload")
        clock.advance(3)
        XCTAssertEqual(ring.app(forPresented: craft), .craft)

        // Thread mints the stack secret itself on first start; Sewn's ring picks it up the same way.
        let stack = try test.home.ensureSecret(for: .stack)
        clock.advance(3)
        XCTAssertEqual(ring.identity(forPresented: stack), .stack)
    }

    func testAMalformedGuessNeverTriggersAReload() throws {
        let test = TestHome()
        _ = try test.home.ensureSecret(for: .ambient)
        let clock = Clock(Date())
        let ring = StackKeyring(home: test.home, minimumReloadInterval: 2, now: { clock.now })
        let craft = try test.home.ensureSecret(for: .craft)
        clock.advance(3)
        XCTAssertNil(ring.app(forPresented: "not-hex"))
        XCTAssertEqual(ring.provisionedApps, [.ambient], "a malformed value earned no read")
        XCTAssertEqual(ring.app(forPresented: craft), .craft)
    }

    func testAnOldRingReloadsSoARevokedSecretStopsWorking() throws {
        let test = TestHome()
        let secrets = try test.home.provision(by: .ambient)
        let clock = Clock(Date())
        let ring = StackKeyring(home: test.home, maximumAge: 60, now: { clock.now })
        try FileManager.default.removeItem(at: test.home.secretFile(for: .veil))
        XCTAssertEqual(ring.app(forPresented: secrets[.app(.veil)]), .veil)
        clock.advance(61)
        XCTAssertNil(ring.app(forPresented: secrets[.app(.veil)]))
    }

    func testAnOpenFileIsSkippedAndSharedValuesDropBothIdentities() throws {
        let test = TestHome()
        let secrets = try test.home.provision(by: .ambient)
        chmod(PrivateFile.path(test.home.secretFile(for: .veil)), 0o644)
        try PrivateFile.writeAtomically(Data(secrets[.app(.ambient)]!.utf8), to: test.home.secretFile(for: .craft))
        let ring = StackKeyring(home: test.home)
        XCTAssertEqual(ring.provisionedIdentities, [.stack], "veil skipped; ambient and craft dropped together")
        XCTAssertEqual(ring.lastIssues.count, 2)
        XCTAssertNil(ring.app(forPresented: secrets[.app(.ambient)]))
    }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}
