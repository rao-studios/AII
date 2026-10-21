//
//  MultiAppStackTests.swift
//  SewnTests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  A shared ~/.rao Sewn holds one secret per app. The secret a request
//  carries says which app is calling — the middleware records it on the
//  context — and /health proves whichever app's secret X-AII-App asks for.
//  An open server's /health JSON must stay byte-for-byte what it was.
//

import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import AII
import XCTest
@testable import Sewn

final class MultiAppStackTests: XCTestCase {

    private typealias KAT = StackSecretTests.KAT

    private let shared = StackMode.multiApp(StackKeyring(fixed: [
        .app(.ambient): "s3cret", .app(.craft): "other", .stack: "stack-secret",
    ]))

    /// The real middleware and /health, plus a route that says who called.
    private func app(_ stack: StackMode) -> some ApplicationProtocol {
        let router = Router(context: SewnRequestContext.self)
        if stack.isLocal {
            router.middlewares.add(StackSecretMiddleware<SewnRequestContext>(mode: stack))
        }
        registerHealthRoute(router, stack: stack)
        router.get("/v1/whoami") { _, context in
            context.callerApp?.rawValue ?? "none"
        }
        return Application(router: router)
    }

    func testEachAppsSecretNamesThatApp() async throws {
        try await app(shared).test(.router) { client in
            try await client.execute(uri: "/v1/whoami", method: .get, headers: [.ambientSecret: "s3cret"]) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(String(buffer: response.body), "ambient")
            }
            try await client.execute(uri: "/v1/whoami", method: .get, headers: [.ambientSecret: "other"]) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(String(buffer: response.body), "craft")
            }
        }
    }

    /// The stack's own identity (`secrets/aii`, Thread's registration) opens the
    /// routes but is no app: it has no lane, no local-only grant, and /health
    /// proves it by name.
    func testTheStackIdentityIsAdmittedAsNoApp() async throws {
        try await app(shared).test(.router) { client in
            try await client.execute(uri: "/v1/whoami", method: .get, headers: [.ambientSecret: "stack-secret"]) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(String(buffer: response.body), "none")
            }
            try await client.execute(
                uri: "/health", method: .get,
                headers: [.ambientNonce: KAT.nonce, .aiiApp: "aii"]) { response in
                let body = String(buffer: response.body)
                XCTAssertTrue(body.contains("\"proof\":\"\(StackSecret.proof(nonce: KAT.nonce, secret: "stack-secret"))\""), body)
                XCTAssertTrue(body.contains("\"app\":\"aii\""), body)
            }
        }
        XCTAssertEqual(shared.admit(authority: "127.0.0.1:47080", presented: "stack-secret"), .admitted(.stack))
        XCTAssertNil(try shared.admittedApp(authority: "127.0.0.1:47080", presented: "stack-secret"))
    }

    func testAnUnknownSecretIsRefused() async throws {
        try await app(shared).test(.router) { client in
            try await client.execute(uri: "/v1/whoami", method: .get, headers: [.ambientSecret: "nope"]) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
            try await client.execute(uri: "/v1/whoami", method: .get) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
            try await client.execute(
                uri: "/v1/whoami", method: .get,
                headers: [.ambientSecret: "s3cret", .aiiApp: "craft"]) { response in
                XCTAssertEqual(String(buffer: response.body), "ambient",
                               "the app is the secret that matched, never a header the client picked")
            }
        }
    }

    func testABadHostIsRefusedEvenWithASecret() {
        XCTAssertEqual(shared.admit(authority: "evil.example:47080", presented: "s3cret"), .notLoopback)
        XCTAssertThrowsError(try shared.admittedApp(authority: "evil.example:47080", presented: "s3cret")) { error in
            XCTAssertEqual((error as? HTTPError)?.status, .misdirectedRequest)
        }
        XCTAssertEqual(try shared.admittedApp(authority: "127.0.0.1:47080", presented: "other"), .craft)
    }

    func testHealthProvesTheRequestedAppsSecret() async throws {
        try await app(shared).test(.router) { client in
            try await client.execute(
                uri: "/health", method: .get,
                headers: [.ambientNonce: KAT.nonce, .aiiApp: "craft"]) { response in
                XCTAssertEqual(response.status, .ok)
                let body = String(buffer: response.body)
                XCTAssertTrue(body.contains("\"stack\":\"proof\""), body)
                XCTAssertTrue(body.contains("\"proof\":\"\(KAT.proofForOther)\""), body)
                XCTAssertTrue(body.contains("\"app\":\"craft\""), body)
                XCTAssertTrue(body.contains("\"contract\":\(AIIContract.version)"), body)
                XCTAssertFalse(body.contains("other"), "the secret never crosses on /health: \(body)")
            }
            try await client.execute(
                uri: "/health", method: .get,
                headers: [.ambientNonce: KAT.nonce, .aiiApp: "ambient"]) { response in
                let body = String(buffer: response.body)
                XCTAssertTrue(body.contains("\"proof\":\"\(KAT.proofForS3cret)\""), body)
                XCTAssertTrue(body.contains("\"app\":\"ambient\""), body)
            }
        }
    }

    func testHealthProvesNothingForAnUnknownApp() async throws {
        try await app(shared).test(.router) { client in
            for requested in ["veil", "nope", ""] {
                try await client.execute(
                    uri: "/health", method: .get,
                    headers: [.ambientNonce: KAT.nonce, .aiiApp: requested]) { response in
                    XCTAssertEqual(response.status, .ok, "health is never refused")
                    let body = String(buffer: response.body)
                    XCTAssertTrue(body.contains("\"stack\":\"proof\""), body)
                    XCTAssertFalse(body.contains("\"proof\":"), "no proof for \"\(requested)\": \(body)")
                    XCTAssertFalse(body.contains("\"app\":"), "no app for \"\(requested)\": \(body)")
                    XCTAssertTrue(body.contains("\"contract\":\(AIIContract.version)"), body)
                }
            }
            try await client.execute(uri: "/health", method: .get, headers: [.ambientNonce: KAT.nonce]) { response in
                let body = String(buffer: response.body)
                XCTAssertFalse(body.contains("\"proof\":"), "no app asked for: \(body)")
            }
        }
    }

    func testAnOpenServersHealthIsUnchanged() async throws {
        try await app(.open).test(.router) { client in
            try await client.execute(
                uri: "/health", method: .get,
                headers: [.ambientNonce: KAT.nonce, .aiiApp: "ambient"]) { response in
                XCTAssertEqual(response.status, .ok)
                let body = String(buffer: response.body)
                XCTAssertTrue(body.contains("\"status\":\"healthy\""), body)
                XCTAssertTrue(body.contains("\"stack\":\"open\""), body)
                XCTAssertTrue(body.contains("\"contract\":\(AIIContract.version)"), "the contract is answered by every build: \(body)")
                for key in ["proof", "app"] {
                    XCTAssertFalse(body.contains("\"\(key)\""), "an open server sends no \(key) key, not even null: \(body)")
                }
                let keys = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
                XCTAssertEqual(Set(keys?.keys.map { $0 } ?? []), ["status", "timestamp", "stack", "contract"])
            }
        }
    }

    func testTheModeSaysWhatItIsWithoutASecret() {
        XCTAssertTrue(shared.isLocal)
        XCTAssertNotNil(shared.grpcResolver)
        XCTAssertEqual(shared.grpcResolver?("other"), "craft")
        XCTAssertNil(shared.grpcResolver?("nope"))
        XCTAssertFalse(shared.summary.contains("s3cret"))
        XCTAssertFalse(shared.summary.contains("other"))
    }
}
