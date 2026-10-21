//
//  LocalOnlyGrantTests.swift
//  SewnTests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  A local app with no account may take the lane: the stack secret names it, and
//  on thirteen routes that is identity enough. It is answered as its lane's owner
//  in the manifest: its own (local-<app>) or the shared aii-local. Everywhere
//  else a bearer is still required, an open server grants nothing, a presented
//  token is never downgraded, and a local-only caller reaches a hosted provider
//  only when the stack holds its key: without one it is a 503 naming the key,
//  before anything is dialled, and naming nothing never reaches a vendor by
//  omission.
//

import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Logging
import AII
import XCTest
@testable import Sewn

final class LocalOnlyGrantTests: XCTestCase {

    private let shared = StackMode.multiApp(StackKeyring(fixed: [.ambient: "s3cret", .craft: "other"]))

    private static let rejectEveryToken: AuthMiddleware.Validate = { _ in
        throw HTTPError(.unauthorized, message: "Invalid or expired access token")
    }
    private static let alice = "0B9E2C1A-5D3F-4E6B-9A7C-1234567890AB"
    private static let acceptAsAlice: AuthMiddleware.Validate = { _ in
        TokenValidator.ValidatedUser(userId: alice, displayName: "Alice", expiresAt: .distantFuture)
    }

    /// Who the caller became: owner | lane | token.
    private static func whoami(_ context: SewnRequestContext) -> String {
        "\(context.authUserId ?? "none")|\(context.isLocalOnly ? "local-only" : "account")|\(context.authToken ?? "-")"
    }

    /// The real stack middleware and the real AuthMiddleware; routes at the
    /// real paths that say who the caller became.
    private func app(
        _ stack: StackMode,
        validate: @escaping AuthMiddleware.Validate = rejectEveryToken,
        laneOwner: (@Sendable (AIIApp) -> AIIOwner)? = nil
    ) -> some ApplicationProtocol {
        let router = Router(context: SewnRequestContext.self)
        if stack.isLocal {
            router.middlewares.add(StackSecretMiddleware<SewnRequestContext>(mode: stack))
        }
        var auth = AuthMiddleware(validate: validate)
        if let laneOwner { auth.laneOwner = laneOwner }
        let protected = router.add(middleware: auth)
        protected.post("/v1/chat/completions") { _, c in Self.whoami(c) }
        protected.post("/v1/complete") { _, c in Self.whoami(c) }
        protected.get("/v1/providers") { _, c in Self.whoami(c) }
        protected.post("/v1/providers/local/warm") { _, c in Self.whoami(c) }
        protected.get("/v1/providers/local/models") { _, c in Self.whoami(c) }
        protected.post("/v1/providers/local/download") { _, c in Self.whoami(c) }
        protected.post("/v1/providers/local/remove") { _, c in Self.whoami(c) }
        protected.get("/v1/providers/local/sinatra/traces/:traceId") { _, c in Self.whoami(c) }
        protected.get("/v1/providers/local/sinatra/analysis") { _, c in Self.whoami(c) }
        protected.post("/v1/vision/look") { _, c in Self.whoami(c) }
        protected.post("/v1/vision/ontology") { _, c in Self.whoami(c) }
        protected.get("/v1/threads") { _, c in Self.whoami(c) }
        protected.get("/v1/stats") { _, c in Self.whoami(c) }
        // Not granted: the same path under another method, and three account routes.
        protected.delete("/v1/providers/local/sinatra/traces/:traceId") { _, c in Self.whoami(c) }
        protected.post("/v1/search") { _, c in Self.whoami(c) }
        protected.get("/v1/account/keys") { _, c in Self.whoami(c) }
        protected.get("/v1/account/plan") { _, c in Self.whoami(c) }
        return Application(router: router)
    }

    private static let granted: [(HTTPRequest.Method, String)] = [
        (.post, "/v1/chat/completions"),
        (.post, "/v1/complete"),
        (.get, "/v1/providers"),
        (.post, "/v1/providers/local/warm"),
        (.get, "/v1/providers/local/models"),
        (.post, "/v1/providers/local/download"),
        (.post, "/v1/providers/local/remove"),
        (.get, "/v1/providers/local/sinatra/traces/\(UUID().uuidString)"),
        (.get, "/v1/providers/local/sinatra/analysis"),
        (.post, "/v1/vision/look"),
        (.post, "/v1/vision/ontology"),
        // The index status every app shows, with the app's secret alone.
        (.get, "/v1/threads"),
        (.get, "/v1/stats"),
    ]

    // MARK: - The grant

    func testAGrantedRouteAdmitsTheStacksAppWithoutABearer() async throws {
        try await app(shared).test(.router) { client in
            for (method, uri) in Self.granted {
                try await client.execute(uri: uri, method: method, headers: [.ambientSecret: "s3cret"]) { response in
                    XCTAssertEqual(response.status, .ok, "\(method) \(uri)")
                    XCTAssertEqual(String(buffer: response.body), "local-ambient|local-only|-", "\(method) \(uri)")
                }
            }
            try await client.execute(uri: "/v1/providers", method: .get, headers: [.ambientSecret: "other"]) { response in
                XCTAssertEqual(String(buffer: response.body), "local-craft|local-only|-",
                               "the owner is the app whose secret matched")
            }
        }
    }

    func testEveryOtherProtectedRouteStillWantsABearer() async throws {
        try await app(shared).test(.router) { client in
            let refused: [(HTTPRequest.Method, String)] = [
                (.post, "/v1/search"),
                (.get, "/v1/account/keys"),
                (.get, "/v1/account/plan"),
                (.delete, "/v1/providers/local/sinatra/traces/\(UUID().uuidString)"),
            ]
            for (method, uri) in refused {
                try await client.execute(uri: uri, method: method, headers: [.ambientSecret: "s3cret"]) { response in
                    XCTAssertEqual(response.status, .unauthorized, "\(method) \(uri)")
                }
            }
        }
    }

    /// With no account, an app is answered as its lane's owner (the manifest's, through the
    /// lane registry Sewn holds): aii-local when it opted in, else its own. An account wins.
    func testANoAccountAppIsAnsweredAsItsLanesOwner() async throws {
        let owners: @Sendable (AIIApp) -> AIIOwner = { $0 == .ambient ? .local : .app($0) }
        try await app(shared, laneOwner: owners).test(.router) { client in
            try await client.execute(uri: "/v1/providers", method: .get, headers: [.ambientSecret: "s3cret"]) { response in
                XCTAssertEqual(String(buffer: response.body), "aii-local|local-only|-", "opted in")
            }
            try await client.execute(uri: "/v1/providers", method: .get, headers: [.ambientSecret: "other"]) { response in
                XCTAssertEqual(String(buffer: response.body), "local-craft|local-only|-", "its own")
            }
        }
        try await app(shared, validate: Self.acceptAsAlice, laneOwner: owners).test(.router) { client in
            try await client.execute(
                uri: "/v1/providers", method: .get,
                headers: [.ambientSecret: "s3cret", .authorization: "Bearer good"]) { response in
                XCTAssertEqual(String(buffer: response.body), "\(Self.alice)|account|good", "an account always wins")
            }
        }
    }

    /// The stack itself (the aii command) manages the on-device models with no account,
    /// as `aii-local`, and reaches nothing else: no chat, no lane.
    func testTheStackIdentityReachesTheModelRoutesOnly() async throws {
        let stack = StackMode.multiApp(StackKeyring(fixed: [.app(.ambient): "s3cret", .stack: "stack-secret"]))
        try await app(stack).test(.router) { client in
            let managed: [(HTTPRequest.Method, String)] = [
                (.get, "/v1/providers"),
                (.get, "/v1/providers/local/models"),
                (.post, "/v1/providers/local/download"),
                (.post, "/v1/providers/local/remove"),
            ]
            for (method, uri) in managed {
                try await client.execute(uri: uri, method: method, headers: [.ambientSecret: "stack-secret"]) { response in
                    XCTAssertEqual(response.status, .ok, "\(method) \(uri)")
                    XCTAssertEqual(String(buffer: response.body), "aii-local|local-only|-", "\(method) \(uri)")
                }
            }
            let refused: [(HTTPRequest.Method, String)] = [
                (.post, "/v1/chat/completions"),
                (.post, "/v1/complete"),
                (.post, "/v1/providers/local/warm"),
                (.get, "/v1/stats"),
                (.post, "/v1/search"),
            ]
            for (method, uri) in refused {
                try await client.execute(uri: uri, method: method, headers: [.ambientSecret: "stack-secret"]) { response in
                    XCTAssertEqual(response.status, .unauthorized, "\(method) \(uri)")
                }
            }
        }
    }

    func testAnOpenServerGrantsNothing() async throws {
        try await app(.open).test(.router) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
        }
    }

    func testAPresentedBearerIsNeverDowngraded() async throws {
        try await app(shared).test(.router) { client in
            for header in ["Bearer bad", "Bearer ", "Basic x"] {
                try await client.execute(
                    uri: "/v1/providers", method: .get,
                    headers: [.ambientSecret: "s3cret", .authorization: header]) { response in
                    XCTAssertEqual(response.status, .unauthorized, "\"\(header)\" must not fall back to the grant")
                }
            }
        }
        try await app(shared, validate: Self.acceptAsAlice).test(.router) { client in
            try await client.execute(
                uri: "/v1/providers", method: .get,
                headers: [.ambientSecret: "s3cret", .authorization: "Bearer good"]) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(String(buffer: response.body), "\(Self.alice)|account|good")
            }
        }
    }

    // MARK: - The provider rule

    /// The keys the stack holds, for the rule; on device never needs one.
    private static func keys(_ present: Set<LLMProvider>) -> (LLMProvider) -> Bool {
        { $0.isLocal || present.contains($0) }
    }

    private static func assertMissingKey(_ error: Error, _ envVar: String, _ message: String = "") {
        let http = error as? HTTPError
        XCTAssertEqual(http?.status, .serviceUnavailable, message)
        XCTAssertTrue(http?.body?.contains("Missing \(envVar)") == true, "\(message) \(String(describing: http?.body))")
    }

    func testALocalOnlyCallerRunsOnDeviceOrOnTheKeyTheStackHolds() throws {
        let mistral = Self.keys([.mistral])
        XCTAssertEqual(try LocalOnlyGrant.provider(requested: .local, isLocalOnly: true, app: .ambient, keyPresent: mistral), .local)
        XCTAssertEqual(try LocalOnlyGrant.provider(requested: .mistral, isLocalOnly: true, app: .ambient, keyPresent: mistral), .mistral,
                       "the person's own key is reason enough")
        XCTAssertThrowsError(try LocalOnlyGrant.provider(requested: .tinker, isLocalOnly: true, app: .ambient, keyPresent: mistral)) {
            Self.assertMissingKey($0, "TINKER_API_KEY")
        }
        for hosted in [LLMProvider.mistral, .tinker] {
            XCTAssertThrowsError(try LocalOnlyGrant.provider(requested: hosted, isLocalOnly: true, app: .ambient, keyPresent: Self.keys([]))) {
                Self.assertMissingKey($0, hosted.hostedBase!.apiKeyEnvVar, "\(hosted): a missing key is a 503, never a sign-in prompt")
            }
        }
        for any in LLMProvider.allCases {
            XCTAssertEqual(try LocalOnlyGrant.provider(requested: any, isLocalOnly: false, app: nil, keyPresent: Self.keys([])), any,
                           "an account is never refused a provider here")
        }
    }

    func testNamingNoProviderFollowsTheKeysTheStackHolds() throws {
        let key = "SEWN_GLOBAL_LLM"
        let previous = ProcessInfo.processInfo.environment[key]
        defer {
            if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
        }
        unsetenv(key)   // the server default: Mistral
        XCTAssertEqual(try LocalOnlyGrant.provider(requested: nil, isLocalOnly: true, app: .ambient, keyPresent: Self.keys([.mistral])), .mistral)
        XCTAssertEqual(try LocalOnlyGrant.provider(requested: nil, isLocalOnly: true, app: .ambient, keyPresent: Self.keys([.mistral, .tinker])), .mistral,
                       "the server default wins when its key is there")
        XCTAssertEqual(try LocalOnlyGrant.provider(requested: nil, isLocalOnly: true, app: .ambient, keyPresent: Self.keys([.tinker])), .tinker,
                       "the one key the stack holds")
        XCTAssertEqual(try LocalOnlyGrant.provider(requested: nil, isLocalOnly: true, app: .ambient, keyPresent: Self.keys([])), .local,
                       "no key: on device, never a refusal by omission")
        setenv(key, "local", 1)
        XCTAssertEqual(try LocalOnlyGrant.provider(requested: nil, isLocalOnly: true, app: .ambient, keyPresent: Self.keys([.mistral])), .local,
                       "a local default stays on device, key or not")
        XCTAssertEqual(try LocalOnlyGrant.provider(requested: nil, isLocalOnly: false, app: nil, keyPresent: Self.keys([])), .local,
                       "an account follows the server default")
    }

    /// Pictures always go to Mistral's vision model when hosted, so the key that matters
    /// is Mistral's, whatever provider was named.
    func testPicturesNeedTheMistralKeyWhateverIsNamed() throws {
        XCTAssertEqual(try LocalOnlyGrant.visionProvider(requested: .tinker, isLocalOnly: true, app: .ambient, keyPresent: Self.keys([.mistral])), .tinker)
        XCTAssertThrowsError(try LocalOnlyGrant.visionProvider(requested: .tinker, isLocalOnly: true, app: .ambient, keyPresent: Self.keys([.tinker]))) {
            Self.assertMissingKey($0, "MISTRAL_API_KEY", "tinker named, but pictures need Mistral's key")
        }
        XCTAssertEqual(try LocalOnlyGrant.visionProvider(requested: nil, isLocalOnly: true, app: .ambient, keyPresent: Self.keys([.tinker])), .local,
                       "no Mistral key: on device")
        XCTAssertEqual(try LocalOnlyGrant.visionProvider(requested: .local, isLocalOnly: true, app: .ambient, keyPresent: Self.keys([])), .local)
        XCTAssertEqual(try LocalOnlyGrant.visionProvider(requested: .tinker, isLocalOnly: false, app: nil, keyPresent: Self.keys([])), .tinker,
                       "an account is never refused here")
    }

    /// The real routes, with no bearer and no key in this process: a hosted provider is a
    /// 503 naming the key, before retrieval, Sinatra or a model is touched, and naming
    /// nothing falls to on device. Never a model load here: on a Mac with MLX built it
    /// would run one, so every on-device case names a model the lane cannot load.
    func testTheRealRoutesAnswer503ToAHostedProviderWithNoKey() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["AII_HOME"] != nil,
                      "AII_HOME is set: the real provider file would decide, and a key there would dial Mistral")
        let keyNames = [ProviderKeyStore.mistralAPIKey, ProviderKeyStore.tinkerAPIKey]
        let previous = keyNames.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        defer {
            for (name, value) in previous { if let value { setenv(name, value, 1) } else { unsetenv(name) } }
        }
        for name in keyNames { unsetenv(name) }

        let router = Router(context: SewnRequestContext.self)
        router.middlewares.add(StackSecretMiddleware<SewnRequestContext>(mode: shared))
        let protected = router.add(middleware: AuthMiddleware(validate: Self.rejectEveryToken))
        let modelProvider = ModelProvider(logger: Logger(label: "local-only-grant-tests"))
        try registerChatCompletionsRoute(protected, SewnCore(stack: shared), modelProvider: modelProvider)
        registerCompleteRoute(protected, modelProvider: modelProvider)
        registerVisionLookRoute(protected, vision: modelProvider.vision)
        registerVisionOntologyRoute(protected, vision: modelProvider.vision)
        let headers: HTTPFields = [.ambientSecret: "s3cret", .contentType: "application/json"]

        try await Application(router: router).test(.router) { client in
            for stream in [false, true] {
                let chat = #"{"messages":[{"role":"user","content":"hi"}],"provider":"mistral","stream":\#(stream),"sewn":{"owner_id":"whatever"}}"#
                try await client.execute(
                    uri: "/v1/chat/completions", method: .post, headers: headers,
                    body: ByteBuffer(string: chat)) { response in
                    XCTAssertEqual(response.status, .serviceUnavailable, "stream: \(stream): before the stream's 200")
                    XCTAssertTrue(String(buffer: response.body).contains("Missing MISTRAL_API_KEY"),
                                  String(buffer: response.body))
                }
            }
            let complete = #"{"messages":[{"role":"user","content":"hi"}],"provider":"tinker"}"#
            try await client.execute(
                uri: "/v1/complete", method: .post, headers: headers,
                body: ByteBuffer(string: complete)) { response in
                XCTAssertEqual(response.status, .serviceUnavailable)
                XCTAssertTrue(String(buffer: response.body).contains("Missing TINKER_API_KEY"), String(buffer: response.body))
            }
            // Pictures: any hosted provider named needs Mistral's key.
            let image = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
            for provider in ["mistral", "tinker"] {
                let look = #"{"image":"\#(image)","media_type":"image/png","mode":"describe","provider":"\#(provider)"}"#
                try await client.execute(
                    uri: "/v1/vision/look", method: .post, headers: headers,
                    body: ByteBuffer(string: look)) { response in
                    XCTAssertEqual(response.status, .serviceUnavailable, "look \(provider)")
                    XCTAssertTrue(String(buffer: response.body).contains("Missing MISTRAL_API_KEY"), "look \(provider)")
                }
                let ontology = #"{"image":"\#(image)","media_type":"image/png","provider":"\#(provider)"}"#
                try await client.execute(
                    uri: "/v1/vision/ontology", method: .post, headers: headers,
                    body: ByteBuffer(string: ontology)) { response in
                    XCTAssertEqual(response.status, .serviceUnavailable, "ontology \(provider)")
                    XCTAssertTrue(String(buffer: response.body).contains("Missing MISTRAL_API_KEY"), "ontology \(provider)")
                }
            }
            // On device is admitted without a bearer — named, or by omission with no key: a
            // model it cannot name is the lane's own 400, reached before anything loads.
            for uri in ["/v1/vision/look", "/v1/vision/ontology"] {
                for provider in [#","provider":"local""#, ""] {
                    let local = #"{"image":"\#(image)","media_type":"image/png","mode":"describe","model":"not a model"\#(provider)}"#
                    try await client.execute(
                        uri: uri, method: .post, headers: headers, body: ByteBuffer(string: local)) { response in
                        XCTAssertEqual(response.status, .badRequest, "\(uri) \(provider)")
                        XCTAssertTrue(String(buffer: response.body).contains("not an on-device vision model"),
                                      String(buffer: response.body))
                    }
                }
            }
        }
    }

    // MARK: - Pins

    func testTheLocalOwnerIsNamedForTheApp() {
        XCTAssertEqual(LocalOnlyGrant.ownerId(for: .ambient), "local-ambient",
                       "Ambient's SewnSession.localOwnerID mirrors this string")
        XCTAssertNil(UUID(uuidString: LocalOnlyGrant.ownerId(for: .ambient)),
                     "a Supabase id is a UUID; a local owner can never collide with one")
    }
}
