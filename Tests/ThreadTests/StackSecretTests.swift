//
//  StackSecretTests.swift
//  ThreadTests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  The shared stack: one Thread serves every app. It answers only requests that
//  carry one of the stack's secrets and name this machine by loopback, proves
//  the identity X-AII-App names, and cuts every request to the lane of the
//  identity that called. Without a home nothing is configured — hosted and dev
//  servers stay open.
//

import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import AII
import XCTest
@testable import Thread

final class StackSecretTests: XCTestCase {

    /// Known answers, shared with Ambient's, Sewn's and AII's tests.
    /// Computed with
    /// `printf '%s' 'ambient-stack-health-v1:<nonce>' | openssl dgst -sha256 -hmac '<secret>'`.
    private enum KAT {
        static let nonce = "000102030405060708090a0b0c0d0e0f"
        static let proofForS3cret = "eb9c34a43319f28ce0a8af801edaf4e6f7d588ed4c16d8edf05e4ed6db53272c"
        static let proofForOther = "320c7f0d1afe5b81c3875afe27948389026503d31477a92543a13e7ef1843ba2"
    }

    func testOnlyTheExactSecretMatches() {
        XCTAssertTrue(StackSecret.matches("s3cret", secret: "s3cret"))
        XCTAssertFalse(StackSecret.matches("s3cres", secret: "s3cret"))
        XCTAssertFalse(StackSecret.matches("s3cret-and-more", secret: "s3cret"))
        XCTAssertFalse(StackSecret.matches(nil, secret: "s3cret"))
        XCTAssertFalse(StackSecret.matches("anything", secret: nil))
    }

    private func oneApp(_ secret: String) -> StackMode { .multiApp(StackKeyring(fixed: [StackIdentity.app(.ambient): secret])) }

    func testHealthProvesTheSecretForANonce() {
        let mode = oneApp("s3cret")
        XCTAssertEqual(mode.healthAnswer(nonce: KAT.nonce, requestedApp: "ambient").proof, KAT.proofForS3cret)

        let unchallenged = oneApp("s").healthAnswer(nonce: nil, requestedApp: "ambient")
        XCTAssertEqual(unchallenged.stack, "proof")
        XCTAssertNil(unchallenged.proof)

        for malformed in ["zz", "", String(repeating: "ab", count: 100)] {
            let answer = oneApp("s").healthAnswer(nonce: malformed, requestedApp: "ambient")
            XCTAssertEqual(answer.stack, "proof", malformed)
            XCTAssertNil(answer.proof, "a malformed nonce earns no proof: \(malformed)")
        }

        let open = StackMode.open.healthAnswer(nonce: KAT.nonce, requestedApp: nil)
        XCTAssertEqual(open.stack, "open")
        XCTAssertNil(open.proof)
        XCTAssertEqual(open.contract, AIIContract.version)

        let uppercase = mode.healthAnswer(nonce: KAT.nonce.uppercased(), requestedApp: "ambient")
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
        }
        for host in ["evil.example:47080", "127.0.0.1.evil.example", "192.168.1.4:47080", "", "[::2]:1"] {
            XCTAssertFalse(StackSecret.isLoopback(authority: host), host)
        }
        XCTAssertFalse(StackSecret.isLoopback(authority: nil))
    }

    func testARebindingPageIsRefusedEvenWithTheSecret() {
        XCTAssertEqual(StackMode.multiApp(.test).admit(authority: "evil.example:47080", presented: "ambient-secret"),
                       .notLoopback)
        XCTAssertEqual(StackMode.open.admit(authority: "evil.example", presented: nil), .admitted(nil),
                       "no stack: nothing is refused")
    }

    func testASharedThreadAcceptsEveryIdentitysSecret() {
        let shared = StackMode.multiApp(.test)
        XCTAssertEqual(shared.admit(authority: "127.0.0.1:47081", presented: "ambient-secret"), .admitted(.app(.ambient)))
        XCTAssertEqual(shared.admit(authority: "127.0.0.1:47081", presented: "craft-secret"), .admitted(.app(.craft)))
        XCTAssertEqual(shared.admit(authority: "127.0.0.1:47081", presented: "aii-secret"), .admitted(.stack))
        XCTAssertEqual(shared.admit(authority: "127.0.0.1:47081", presented: "other"), .badSecret)
        XCTAssertEqual(shared.admit(authority: "127.0.0.1:47081", presented: nil), .badSecret)
    }

    // MARK: - Through the middleware and the real /health route

    private func app(mode: StackMode) -> some ApplicationProtocol {
        let router = Router(context: ThreadRequestContext.self)
        router.middlewares.add(StackSecretMiddleware<ThreadRequestContext>(mode: mode))
        registerHealthRoute(router, stack: mode)
        router.post("/v1/clear") { _, _ in "cleared" }
        return Application(router: router)
    }

    func testHealthAnswersAChallengeWithoutTheSecret() async throws {
        try await app(mode: oneApp("s3cret")).test(.router) { client in
            try await client.execute(
                uri: "/health", method: .get,
                headers: [.ambientNonce: KAT.nonce, .aiiApp: "ambient"]) { response in
                XCTAssertEqual(response.status, .ok)
                let body = String(buffer: response.body)
                XCTAssertTrue(body.contains("\"proof\":\"\(KAT.proofForS3cret)\""), body)
                XCTAssertTrue(body.contains("\"app\":\"ambient\""), body)
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

    func testAnOpenThreadsHealthNamesOnlyTheContract() async throws {
        try await app(mode: .open).test(.router) { client in
            try await client.execute(uri: "/health", method: .get, headers: [.ambientNonce: KAT.nonce]) { response in
                let body = String(buffer: response.body)
                XCTAssertTrue(body.contains("\"stack\":\"open\""), body)
                XCTAssertFalse(body.contains("\"proof\""), body)
                XCTAssertFalse(body.contains("\"app\""), body)
                XCTAssertTrue(body.contains("\"contract\":\(AIIContract.version)"), body)
            }
        }
    }

    func testWithoutTheSecretNothingButHealthAnswers() async throws {
        try await app(mode: oneApp("s")).test(.router) { client in
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
        try await app(mode: oneApp("s")).test(.router) { client in
            try await client.execute(
                uri: "/v1/clear", method: .post,
                headers: [.ambientSecret: "s"]) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
    }

    func testWithNoHomeEverythingIsOpen() async throws {
        try await app(mode: .open).test(.router) { client in
            try await client.execute(uri: "/v1/clear", method: .post) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
    }

    /// Every launcher challenges the shared Thread as its own app, so the proof must
    /// be for the identity X-AII-App names — a Thread that ignored the header would
    /// read as `.stale` to each of them and be respawned forever.
    func testASharedThreadsHealthProvesTheIdentityNamed() async throws {
        try await app(mode: .multiApp(.test)).test(.router) { client in
            try await client.execute(
                uri: "/health", method: .get,
                headers: [.ambientNonce: KAT.nonce, .aiiApp: "craft"]) { response in
                XCTAssertEqual(response.status, .ok)
                let body = String(buffer: response.body)
                XCTAssertTrue(body.contains("\"proof\":\"\(StackSecret.proof(nonce: KAT.nonce, secret: "craft-secret"))\""), body)
                XCTAssertTrue(body.contains("\"app\":\"craft\""), body)
                XCTAssertTrue(body.contains("\"contract\":\(AIIContract.version)"), body)
            }
            try await client.execute(
                uri: "/health", method: .get,
                headers: [.ambientNonce: KAT.nonce, .aiiApp: "aii"]) { response in
                let body = String(buffer: response.body)
                XCTAssertTrue(body.contains("\"app\":\"aii\""), "the stack identity is proven too: \(body)")
            }
            try await client.execute(uri: "/health", method: .get, headers: [.ambientNonce: KAT.nonce]) { response in
                let body = String(buffer: response.body)
                XCTAssertFalse(body.contains("\"proof\":\""), "no identity named, no proof: \(body)")
            }
            // Every identity's secret opens the routes.
            for secret in ["ambient-secret", "veil-secret", "aii-secret"] {
                try await client.execute(uri: "/v1/clear", method: .post, headers: [.ambientSecret: secret]) { response in
                    XCTAssertEqual(response.status, .ok, secret)
                }
            }
            try await client.execute(uri: "/v1/clear", method: .post, headers: [.ambientSecret: "stranger"]) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
        }
    }
}

final class AIIHomeLaunchTests: XCTestCase {

    func testTheDataDirectoryOrder() {
        XCTAssertEqual(ThreadServer.resolveDataDirectory(argument: "/flag", environment: ["THREAD_DATA_DIR": "/env"]), "/flag")
        XCTAssertEqual(ThreadServer.resolveDataDirectory(argument: nil, environment: ["THREAD_DATA_DIR": "/env"]), "/env")
        XCTAssertEqual(ThreadServer.resolveDataDirectory(argument: nil, environment: ["AII_HOME": "/r"]), "/r/aii/thread/db",
                       "the shared stack: the one index, whichever app launched it")
        XCTAssertNil(ThreadServer.resolveDataDirectory(argument: nil, environment: [:]))
    }

    func testTheMothershipSecretIsTheStacksOnASharedStack() {
        XCTAssertEqual(ThreadServer.mothershipSecret(stack: .multiApp(.test)), "aii-secret")
        XCTAssertNil(ThreadServer.mothershipSecret(stack: .open))
    }

    func testTheMistralKeyFallsBackToTheEnvironment() {
        let store = ProviderKeyStore(home: nil, environment: { ["MISTRAL_API_KEY": "from-env"] })
        XCTAssertEqual(store.value(for: ProviderKeyStore.mistralAPIKey), "from-env")
        XCTAssertEqual(ProviderKeyStore.process.isFileBacked, ProcessInfo.processInfo.environment["AII_HOME"] != nil,
                       "a server reads the shared key file only when its launcher set AII_HOME")
    }
}
