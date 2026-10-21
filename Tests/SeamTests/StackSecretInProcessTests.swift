//
//  StackSecretInProcessTests.swift
//  SeamTests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  The two halves of the contract meeting over a real (in-process) gRPC
//  transport: Register is UNAUTHENTICATED without the secret, accepted with
//  it, and a server given no resolver stays open.
//

import Foundation
import GRPCCore
import XCTest
@testable import Seam

/// The smallest keyring: one secret, one identity.
private func oneSecret(_ secret: String) -> StackSecretResolver { { $0 == secret ? "ambient" : nil } }

final class StackSecretInProcessTests: XCTestCase {

    func testRegisterWithoutTheSecretIsUnauthenticated() async throws {
        let mothership = InProcessMothership()
        try await mothership.run(
            serverInterceptors: [StackSecretServerInterceptor(resolver: oneSecret("s"), logger: mothership.logger)]
        ) { stub in
            do {
                _ = try await stub.register(.sample())
                XCTFail("expected UNAUTHENTICATED")
            } catch let error as RPCError {
                XCTAssertEqual(error.code, .unauthenticated)
            }
        }
        XCTAssertTrue(mothership.logger.warnings.contains { $0.contains("thread.v1.ThreadRegistration/Register") })
    }

    func testRegisterWithTheSecretIsAccepted() async throws {
        let mothership = InProcessMothership()
        let response = try await mothership.run(
            serverInterceptors: [StackSecretServerInterceptor(resolver: oneSecret("s"), logger: mothership.logger)],
            clientInterceptors: [StackSecretClientInterceptor(secret: "s")]
        ) { stub in
            try await stub.register(.sample())
        }
        XCTAssertTrue(response.accepted)
        XCTAssertEqual(response.mothershipID, mothership.mothershipId.uuidString)
        XCTAssertTrue(mothership.logger.warnings.isEmpty)
    }

    func testWrongSecretIsUnauthenticatedAndNeverLogged() async throws {
        let mothership = InProcessMothership()
        let guess = "not-the-secret-91c2"
        try await mothership.run(
            serverInterceptors: StackSecretServerInterceptor.forLocalMode(resolver: oneSecret("s"), logger: mothership.logger),
            clientInterceptors: [StackSecretClientInterceptor(secret: guess)]
        ) { stub in
            do {
                _ = try await stub.register(.sample())
                XCTFail("expected UNAUTHENTICATED")
            } catch let error as RPCError {
                XCTAssertEqual(error.code, .unauthenticated)
            }
        }
        XCTAssertFalse(mothership.logger.lines.contains { $0.contains(guess) })
    }

    func testAServerWithNoSecretStaysOpen() async throws {
        let mothership = InProcessMothership()
        let response = try await mothership.run(
            serverInterceptors: StackSecretServerInterceptor.forLocalMode(resolver: nil)
        ) { stub in
            try await stub.register(.sample())
        }
        XCTAssertTrue(response.accepted)
    }
}
