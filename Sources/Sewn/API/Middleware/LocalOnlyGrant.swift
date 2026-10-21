//
//  LocalOnlyGrant.swift
//  Sewn
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The lane with no account. A caller the stack secret already named
//        (StackSecretMiddleware: loopback, secret verified) may reach a short
//        list of routes with no bearer, acting as its lane's owner
//        ("local-<app>" or "aii-local"), and runs on device or on any hosted
//        provider whose key the stack holds (keys/providers.json): a key is
//        the person's own, so it is reason enough. The stack itself (the aii
//        command) may reach fewer still: the provider list and the on-device
//        models, as "aii-local", to manage them.
//  IN:   AuthMiddleware (the grant); the chat, complete and vision handlers
//        (the provider rule, before anything is dialled).
//  OUT:  `admits(method:endpointPath:)`, `ownerId(for:)`,
//        `provider(requested:isLocalOnly:app:keyPresent:)` and its vision twin.
//  PIN:  The list is exact endpoint patterns, never prefixes: a new route is
//        protected until someone adds it here. Neither `aii-local` nor a
//        `local-<app>` owner can be a Supabase id (those are UUIDs), so
//        on-device data never lands in an account's rows. A presented bearer
//        is always validated; the grant exists only for a request that sent
//        none. A hosted provider with no key is a 503 naming the key, never a
//        401: there is no account to sign in to here. Naming nothing never
//        reaches a vendor by omission: the server default only when its key is
//        present, else the one hosted provider that has a key, else on device.
//        Ambient mirrors the no-account owner (`aii-local`) in its own tests;
//        change neither alone.
//

import HTTPTypes
import Hummingbird
import AII

enum LocalOnlyGrant {
    struct Route: Hashable, Sendable {
        let method: HTTPRequest.Method
        /// Hummingbird's endpoint description: parameters render as `{name}`.
        let endpointPath: String
    }

    /// Every route a local caller may reach with no bearer. Nothing else.
    static let routes: Set<Route> = [
        Route(method: .post, endpointPath: "/v1/chat/completions"),
        Route(method: .post, endpointPath: "/v1/complete"),
        Route(method: .get, endpointPath: "/v1/providers"),
        Route(method: .post, endpointPath: "/v1/providers/local/warm"),
        Route(method: .get, endpointPath: "/v1/providers/local/models"),
        Route(method: .post, endpointPath: "/v1/providers/local/download"),
        Route(method: .post, endpointPath: "/v1/providers/local/remove"),
        Route(method: .get, endpointPath: "/v1/providers/local/sinatra/traces/{traceId}"),
        Route(method: .get, endpointPath: "/v1/providers/local/sinatra/analysis"),
        // Pictures on this Mac (LocalVision): the same hosted-or-local choice as chat.
        Route(method: .post, endpointPath: "/v1/vision/look"),
        Route(method: .post, endpointPath: "/v1/vision/ontology"),
        // The Ambient Intelligence Index status every app shows: its Thread node(s)
        // and the caller's lane's counts. Read by the AII client with the app's
        // secret alone.
        Route(method: .get, endpointPath: "/v1/threads"),
        Route(method: .get, endpointPath: "/v1/stats"),
    ]

    /// The routes the stack identity may reach with no bearer: what the aii command
    /// manages. No chat, no lane: the stack has none.
    static let stackRoutes: Set<Route> = [
        Route(method: .get, endpointPath: "/v1/providers"),
        Route(method: .get, endpointPath: "/v1/providers/local/models"),
        Route(method: .post, endpointPath: "/v1/providers/local/download"),
        Route(method: .post, endpointPath: "/v1/providers/local/remove"),
    ]

    static func admits(method: HTTPRequest.Method, endpointPath: String?) -> Bool {
        guard let endpointPath else { return false }
        return routes.contains(Route(method: method, endpointPath: endpointPath))
    }

    /// Whether `identity` may reach this route with no bearer.
    static func admits(_ identity: StackIdentity, method: HTTPRequest.Method, endpointPath: String?) -> Bool {
        guard let endpointPath else { return false }
        let route = Route(method: method, endpointPath: endpointPath)
        return identity.isStack ? stackRoutes.contains(route) : routes.contains(route)
    }

    /// An app's own no-account owner, `local-<app>`: what an app answers as when its lane
    /// names no other.
    static func ownerId(for app: AIIApp) -> String {
        AIIOwner.app(app).rawValue
    }

    /// The owner a local-only request acts as: an app's lane owner from the manifest
    /// (`local-<app>` or the shared `aii-local`), and `aii-local` for the stack itself.
    static func ownerId(for identity: StackIdentity,
                        laneOwner: (AIIApp) -> AIIOwner = { .app($0) }) -> String {
        switch identity {
        case .app(let app): return laneOwner(app).rawValue
        case .stack: return AIIOwner.local.rawValue
        }
    }

    /// Whether the stack holds a key for `provider` right now: the shared file, then the
    /// environment, read per call (NetworkService.BaseEndpoint). On device needs none.
    static func keyPresent(_ provider: LLMProvider) -> Bool {
        guard let base = provider.hostedBase else { return true }
        return base.apiKeyIfPresent != nil
    }

    /// The backend a request runs on. An account gets what it named, else the server
    /// default. A local-only caller gets the hosted provider it named when the stack holds
    /// its key, and a 503 naming the key when it doesn't; naming nothing, the server default
    /// when its key is present, else the one hosted provider that has a key, else `.local`.
    static func provider(
        requested: LLMProvider?, isLocalOnly: Bool, app: AIIApp?,
        keyPresent: (LLMProvider) -> Bool = Self.keyPresent
    ) throws -> LLMProvider {
        try resolve(requested: requested, isLocalOnly: isLocalOnly, hostedKey: nil, keyPresent: keyPresent)
    }

    /// The same rule for the vision routes, which call Mistral's vision model whatever hosted
    /// provider was named: the key that matters is Mistral's.
    static func visionProvider(
        requested: LLMProvider?, isLocalOnly: Bool, app: AIIApp?,
        keyPresent: (LLMProvider) -> Bool = Self.keyPresent
    ) throws -> LLMProvider {
        try resolve(requested: requested, isLocalOnly: isLocalOnly, hostedKey: .mistral, keyPresent: keyPresent)
    }

    private static func resolve(
        requested: LLMProvider?, isLocalOnly: Bool, hostedKey: LLMProvider?,
        keyPresent: (LLMProvider) -> Bool
    ) throws -> LLMProvider {
        guard isLocalOnly else { return requested ?? .serverDefault }
        func keyed(_ provider: LLMProvider) -> Bool { provider.isLocal || keyPresent(hostedKey ?? provider) }
        if let requested {
            guard keyed(requested) else { throw missingKey(for: hostedKey ?? requested) }
            return requested
        }
        let preferred = LLMProvider.serverDefault
        if keyed(preferred) { return preferred }
        let withKeys = LLMProvider.allCases.filter { !$0.isLocal && keyed($0) }
        return withKeys.count == 1 ? withKeys[0] : .local
    }

    /// The 503 the downstream key lookup would raise, raised before the stream's 200 and
    /// before retrieval, Sinatra or a model is touched.
    private static func missingKey(for provider: LLMProvider) -> HTTPError {
        let envVar = provider.hostedBase?.apiKeyEnvVar ?? provider.rawValue
        return HTTPError(.serviceUnavailable, message: ProviderUnavailable.missingKey(envVar: envVar).description)
    }
}

extension SewnRequestContext {
    /// `LocalOnlyGrant.provider` for this request. Call it before anything is dialled, and
    /// write the answer back onto the request so every pass of the turn agrees with it.
    func admittedProvider(_ requested: LLMProvider?) throws -> LLMProvider {
        try LocalOnlyGrant.provider(requested: requested, isLocalOnly: isLocalOnly, app: callerApp)
    }

    /// `LocalOnlyGrant.visionProvider` for this request.
    func admittedVisionProvider(_ requested: LLMProvider?) throws -> LLMProvider {
        try LocalOnlyGrant.visionProvider(requested: requested, isLocalOnly: isLocalOnly, app: callerApp)
    }
}
