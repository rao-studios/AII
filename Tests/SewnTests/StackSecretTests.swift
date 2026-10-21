//
//  StackSecretTests.swift
//  SewnTests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  The shared stack: a Sewn launched under AII_HOME answers only requests that
//  carry one of the stack's secrets and name this machine by loopback. Without
//  a home nothing is configured — hosted and dev servers stay open. The
//  primitives live in AII; these tests pin how Sewn uses them through
//  StackMode, its middleware and its /health route.
//

import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import AII
import XCTest
@testable import Sewn

final class StackSecretTests: XCTestCase {

    /// Known answers, shared with Ambient's tests. Computed with
    /// `printf '%s' 'ambient-stack-health-v1:<nonce>' | openssl dgst -sha256 -hmac '<secret>'`.
    enum KAT {
        static let nonce = "000102030405060708090a0b0c0d0e0f"
        static let proofForS3cret = "eb9c34a43319f28ce0a8af801edaf4e6f7d588ed4c16d8edf05e4ed6db53272c"
        static let proofForOther = "320c7f0d1afe5b81c3875afe27948389026503d31477a92543a13e7ef1843ba2"
    }

    /// A stack with one app provisioned: the smallest shared stack there is.
    private func oneApp(_ secret: String) -> StackMode { .multiApp(StackKeyring(fixed: [StackIdentity.app(.ambient): secret])) }

    func testOnlyTheExactSecretMatches() {
        XCTAssertTrue(StackSecret.matches("s3cret", secret: "s3cret"))
        XCTAssertFalse(StackSecret.matches("s3cres", secret: "s3cret"))
        XCTAssertFalse(StackSecret.matches("s3cret-and-more", secret: "s3cret"))
        XCTAssertFalse(StackSecret.matches(nil, secret: "s3cret"))
        XCTAssertFalse(StackSecret.matches("anything", secret: nil))

        XCTAssertEqual(oneApp("s3cret").admit(authority: "localhost", presented: "s3cret"), .admitted(.app(.ambient)))
        XCTAssertEqual(oneApp("s3cret").admit(authority: "localhost", presented: "s3cres"), .badSecret)
        XCTAssertEqual(oneApp("s3cret").admit(authority: "localhost", presented: nil), .badSecret)
    }

    func testHealthProvesTheSecretForANonce() {
        XCTAssertEqual(StackSecret.proof(nonce: KAT.nonce, secret: "s3cret"), KAT.proofForS3cret)

        let unchallenged = oneApp("s").healthAnswer(nonce: nil, requestedApp: "ambient")
        XCTAssertEqual(unchallenged.stack, "proof")
        XCTAssertNil(unchallenged.proof)
        XCTAssertEqual(unchallenged.contract, AIIContract.version)

        for malformed in ["zz", "", String(repeating: "ab", count: 100)] {
            let answer = oneApp("s").healthAnswer(nonce: malformed, requestedApp: "ambient")
            XCTAssertEqual(answer.stack, "proof", malformed)
            XCTAssertNil(answer.proof, "a malformed nonce earns no proof: \(malformed)")
        }
        XCTAssertNil(oneApp("s").healthAnswer(nonce: KAT.nonce, requestedApp: nil).proof, "no identity named, no proof")

        let open = StackMode.open.healthAnswer(nonce: KAT.nonce, requestedApp: nil)
        XCTAssertEqual(open.stack, "open")
        XCTAssertNil(open.proof)
        XCTAssertNil(open.app)
        XCTAssertEqual(open.contract, AIIContract.version)

        let uppercase = oneApp("s3cret").healthAnswer(nonce: KAT.nonce.uppercased(), requestedApp: "ambient")
        XCTAssertEqual(uppercase.stack, "proof")
        XCTAssertNotNil(uppercase.proof, "either case is a well-formed nonce")
        XCTAssertNotEqual(uppercase.proof, KAT.proofForS3cret, "the proof covers the nonce exactly as received")
    }

    func testTheProofIsNotTheSecret() {
        let proof = StackSecret.proof(nonce: KAT.nonce, secret: "s3cret")
        XCTAssertEqual(proof.count, 64)
        XCTAssertTrue(proof.allSatisfy { "0123456789abcdef".contains($0) }, proof)
        XCTAssertNotEqual(proof, "s3cret")
        XCTAssertEqual(StackSecret.proof(nonce: KAT.nonce, secret: "other"), KAT.proofForOther)
    }

    func testOnlyLoopbackHostsAreAnswered() {
        for host in ["127.0.0.1:47080", "localhost:47080", "LOCALHOST", "[::1]:47080", "127.0.0.1"] {
            XCTAssertTrue(StackSecret.isLoopback(authority: host), host)
            XCTAssertEqual(oneApp("s").admit(authority: host, presented: "s"), .admitted(.app(.ambient)), host)
        }
        for host in ["evil.example:47080", "127.0.0.1.evil.example", "192.168.1.4:47080", "", "[::2]:1"] {
            XCTAssertFalse(StackSecret.isLoopback(authority: host), host)
            XCTAssertEqual(oneApp("s").admit(authority: host, presented: "s"), .notLoopback, host)
        }
        XCTAssertFalse(StackSecret.isLoopback(authority: nil))
        XCTAssertEqual(oneApp("s").admit(authority: nil, presented: "s"), .notLoopback)
    }

    func testARebindingPageIsRefusedEvenWithTheSecret() {
        XCTAssertThrowsError(try oneApp("s").admittedApp(authority: "evil.example:47080", presented: "s")) { error in
            XCTAssertEqual((error as? HTTPError)?.status, .misdirectedRequest)
        }
        XCTAssertThrowsError(try oneApp("s").admittedApp(authority: "localhost", presented: "wrong")) { error in
            XCTAssertEqual((error as? HTTPError)?.status, .unauthorized)
        }
        XCTAssertNil(try StackMode.open.admittedApp(authority: "evil.example", presented: nil),
                     "no secret configured: nothing is refused")
    }

    /// The real middleware, the real /health route and the real context.
    private func app(_ stack: StackMode) -> some ApplicationProtocol {
        let router = Router(context: SewnRequestContext.self)
        if stack.isLocal {
            router.middlewares.add(StackSecretMiddleware<SewnRequestContext>(mode: stack))
        }
        registerHealthRoute(router, stack: stack)
        router.post("/v1/clear") { _, _ in "cleared" }
        return Application(router: router)
    }

    func testHealthAnswersAChallengeWithoutTheSecret() async throws {
        try await app(oneApp("s3cret")).test(.router) { client in
            try await client.execute(
                uri: "/health", method: .get,
                headers: [.ambientNonce: KAT.nonce, .aiiApp: "ambient"]) { response in
                XCTAssertEqual(response.status, .ok)
                let body = String(buffer: response.body)
                XCTAssertTrue(body.contains("\"proof\":\"\(KAT.proofForS3cret)\""), body)
                XCTAssertTrue(body.contains("\"contract\":\(AIIContract.version)"), body)
                XCTAssertFalse(body.contains("s3cret"), "the secret never crosses on /health: \(body)")
            }
            try await client.execute(
                uri: "/health", method: .get,
                headers: [.ambientSecret: "s3cret"]) { response in
                XCTAssertEqual(response.status, .ok)
                let body = String(buffer: response.body)
                XCTAssertTrue(body.contains("\"stack\":\"proof\""), body)
                XCTAssertFalse(body.contains("\"proof\":"), "presenting the secret earns no proof, not even null: \(body)")
            }
        }
    }

    func testWithoutTheSecretNothingButHealthAnswers() async throws {
        try await app(oneApp("s")).test(.router) { client in
            try await client.execute(uri: "/v1/clear", method: .post) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
            try await client.execute(
                uri: "/v1/clear", method: .post,
                headers: [.ambientSecret: "wrong"]) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
            try await client.execute(uri: "/health", method: .get) { response in
                XCTAssertEqual(response.status, .ok, "a launcher must be able to ask for proof of the secret")
            }
        }
    }

    func testWithTheSecretTheRouteAnswers() async throws {
        try await app(oneApp("s")).test(.router) { client in
            try await client.execute(
                uri: "/v1/clear", method: .post,
                headers: [.ambientSecret: "s"]) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
    }

    func testWithNoHomeEverythingIsOpen() async throws {
        try await app(.open).test(.router) { client in
            try await client.execute(uri: "/v1/clear", method: .post) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
    }
}
