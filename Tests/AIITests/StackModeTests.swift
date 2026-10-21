//
//  StackModeTests.swift
//  AIITests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  Which mode a server is in, from its environment, and what each mode
//  admits and answers on /health. Two modes only: `multiApp` under AII_HOME,
//  `open` without one.
//

import Foundation
import XCTest
@testable import AII

final class StackModeTests: XCTestCase {
    typealias KAT = StackSecretTests.KAT

    private func oneApp(_ secret: String) -> StackMode {
        .multiApp(StackKeyring(fixed: [StackIdentity.app(.ambient): secret]))
    }

    // MARK: - Sewn's environment

    func testSewnWithNoHomeIsOpen() throws {
        let mode = try StackMode.sewn(environment: [:])
        guard case .open = mode else { return XCTFail("expected open") }
        XCTAssertFalse(mode.isLocal)
        XCTAssertNil(mode.keyring)
        XCTAssertNil(mode.grpcResolver)
    }

    func testSewnWithAHomeHoldsEveryIdentitysSecret() throws {
        let test = TestHome()
        try test.home.provision(by: .ambient)
        let mode = try StackMode.sewn(environment: ["AII_HOME": PrivateFile.path(test.home.root)])
        XCTAssertTrue(mode.isLocal)
        XCTAssertNotNil(mode.keyring)
        XCTAssertEqual(mode.keyring?.provisionedApps, AIIApp.allCases)
        XCTAssertEqual(mode.keyring?.provisionedIdentities, [.stack, .app(.ambient), .app(.craft), .app(.veil)])
    }

    func testSewnRefusesAHomeThatIsMissingOrOpen() throws {
        let test = TestHome()
        XCTAssertThrowsError(try StackMode.sewn(environment: ["AII_HOME": PrivateFile.path(test.home.root)]))
        try test.home.provision(by: .ambient)
        chmod(PrivateFile.path(test.home.root), 0o755)
        XCTAssertThrowsError(try StackMode.sewn(environment: ["AII_HOME": PrivateFile.path(test.home.root)]))
        XCTAssertThrowsError(try StackMode.sewn(environment: ["AII_HOME": "relative"]))
    }

    // MARK: - Thread's environment

    func testAThreadWithNoHomeIsOpen() throws {
        guard case .open = try StackMode.thread(environment: [:]) else { return XCTFail("no home: open") }
    }

    /// The one Thread runs for every app: under AII_HOME it holds the whole keyring.
    func testAThreadWithAHomeHoldsEveryIdentitysSecret() throws {
        let test = TestHome()
        let secrets = try test.home.provision(by: .veil)
        let root = PrivateFile.path(test.home.root)
        let mode = try StackMode.thread(environment: ["AII_HOME": root])
        XCTAssertNotNil(mode.keyring)
        XCTAssertEqual(mode.keyring?.secret(for: .stack), secrets[.stack])
        XCTAssertEqual(mode.grpcResolver?(secrets[.app(.veil)]!), "veil")
        XCTAssertEqual(mode.grpcResolver?(secrets[.stack]!), "aii")
        XCTAssertNil(mode.grpcResolver?("nobody's"))
    }

    func testAThreadToldToUseAHomeNeverComesUpOpen() throws {
        let test = TestHome()
        XCTAssertThrowsError(try StackMode.thread(environment: ["AII_HOME": PrivateFile.path(test.home.root)]), "no such home")
    }

    // MARK: - Admission

    func testOpenAdmitsEveryone() {
        XCTAssertEqual(StackMode.open.admit(authority: "evil.example", presented: nil), .admitted(nil))
        XCTAssertNil(StackMode.open.admit(authority: "evil.example", presented: nil).app)
    }

    func testTheSharedStackChecksHostBeforeSecret() {
        let mode = oneApp("s3cret")
        XCTAssertEqual(mode.admit(authority: "evil.example", presented: "s3cret"), .notLoopback)
        XCTAssertEqual(mode.admit(authority: "127.0.0.1:1", presented: "wrong"), .badSecret)
        XCTAssertEqual(mode.admit(authority: "127.0.0.1:1", presented: nil), .badSecret)
        XCTAssertEqual(mode.admit(authority: "127.0.0.1:1", presented: "s3cret"), .admitted(.app(.ambient)))
        XCTAssertEqual(mode.admit(authority: "127.0.0.1:1", presented: "s3cret").app, .ambient)
    }

    func testMultiAppKnowsTheCallerBySecret() {
        let mode = StackMode.multiApp(StackKeyring(fixed: [StackIdentity.app(.ambient): "s3cret", .app(.craft): "other", .stack: "stacks"]))
        XCTAssertEqual(mode.admit(authority: "localhost:47080", presented: "s3cret"), .admitted(.app(.ambient)))
        XCTAssertEqual(mode.admit(authority: "localhost:47080", presented: "other"), .admitted(.app(.craft)))
        XCTAssertEqual(mode.admit(authority: "localhost:47080", presented: "stacks"), .admitted(.stack))
        XCTAssertNil(mode.admit(authority: "localhost:47080", presented: "stacks").app, "the stack identity has no lane of its own")
        XCTAssertTrue(mode.admit(authority: "localhost:47080", presented: "stacks").isStack)
        XCTAssertEqual(mode.admit(authority: "localhost:47080", presented: "nobody's"), .badSecret)
        XCTAssertEqual(mode.admit(authority: "evil.example", presented: "s3cret"), .notLoopback)
        XCTAssertEqual(mode.grpcResolver?("other"), "craft")
        XCTAssertEqual(mode.grpcResolver?("stacks"), "aii")
        XCTAssertNil(mode.grpcResolver?("nobody's"))
    }

    // MARK: - /health

    func testOpenHealthCarriesOnlyTheContract() throws {
        let answer = StackMode.open.healthAnswer(nonce: KAT.nonce, requestedApp: "ambient")
        XCTAssertEqual(answer, StackHealthAnswer(stack: "open", proof: nil, app: nil, contract: AIIContract.version))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode(answer), as: UTF8.self)
        XCTAssertEqual(json, #"{"contract":\#(AIIContract.version),"stack":"open"}"#, "nil fields are left out, not null")
    }

    func testMultiAppHealthProvesTheRequestedIdentitysSecret() throws {
        let mode = StackMode.multiApp(StackKeyring(fixed: [StackIdentity.app(.ambient): "s3cret", .app(.craft): "other", .stack: "stacks"]))
        let craft = mode.healthAnswer(nonce: KAT.nonce, requestedApp: "craft")
        XCTAssertEqual(craft.proof, KAT.proofForOther)
        XCTAssertEqual(craft.app, .app(.craft))
        XCTAssertEqual(craft.contract, AIIContract.version)
        let json = String(decoding: try JSONEncoder().encode(craft), as: UTF8.self)
        XCTAssertTrue(json.contains(#""app":"craft""#), "the app field is the plain name: \(json)")
        let ambient = mode.healthAnswer(nonce: KAT.nonce, requestedApp: " Ambient ")
        XCTAssertEqual(ambient.proof, KAT.proofForS3cret)
        let stack = mode.healthAnswer(nonce: KAT.nonce, requestedApp: "aii")
        XCTAssertEqual(stack.proof, StackSecret.proof(nonce: KAT.nonce, secret: "stacks"))
        XCTAssertEqual(stack.app, .stack)

        for requested in [nil, "", "bogus", "veil"] {
            let answer = mode.healthAnswer(nonce: KAT.nonce, requestedApp: requested)
            XCTAssertEqual(answer.stack, "proof")
            XCTAssertNil(answer.proof, requested ?? "nil")
            XCTAssertNil(answer.app)
            XCTAssertEqual(answer.contract, AIIContract.version, "the contract is answered whoever asks")
        }
        XCTAssertNil(mode.healthAnswer(nonce: nil, requestedApp: "craft").proof)
        XCTAssertNil(mode.healthAnswer(nonce: "zz", requestedApp: "craft").proof, "a malformed nonce earns no proof")
    }

    func testTheSummaryNeverShowsASecret() {
        let secret = StackSecret.generate()
        XCTAssertFalse(oneApp(secret).summary.contains(secret))
        XCTAssertFalse(StackMode.open.summary.isEmpty)
    }
}
