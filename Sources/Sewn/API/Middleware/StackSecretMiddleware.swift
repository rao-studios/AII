//
//  StackSecretMiddleware.swift
//  Sewn
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The shared stack. When the launcher gives this Sewn a home (AII_HOME),
//        every request must carry one of the stack's secrets in X-Ambient-Secret
//        and address this machine by loopback; the secret that matched says
//        which app is calling.
//  IN:   The StackMode decided once at start (AII's `StackMode.sewn`) from the
//        launcher's environment. Hosted deployments and dev scripts set no home;
//        the middleware isn't installed and nothing changes.
//  OUT:  401 without a secret this Sewn knows; 421 for a Host that isn't
//        loopback; otherwise `context.callerIdentity` and `context.callerApp`:
//        every Thread fan-out is scoped by the app (see `SewnCore.nodeScope(for:)`),
//        and the identity is what lets AuthMiddleware grant the on-device lane with
//        no account (LocalOnlyGrant) — to an app, or to the stack on its few routes.
//  PIN:  Keeps web pages out. A page can't send a custom header cross-site
//        without a CORS preflight, and local mode answers none; a
//        DNS-rebinding page arrives under its own Host and never learns a
//        secret. The caller's app is whichever secret matched — never a
//        header the client picked (X-AII-App is read on /health alone).
//        /health stays open so a launcher can ask for proof of a secret
//        without sending it. The realtime WebSocket router never sees this
//        middleware and makes the same check through `admittedApp`.
//

import HTTPTypes
import Hummingbird
import AII

extension HTTPField.Name {
    /// Every request's stack secret, except on /health.
    static let ambientSecret = HTTPField.Name(StackSecret.headerName)!
    /// /health's challenge. Never the secret.
    static let ambientNonce = HTTPField.Name(StackSecret.nonceHeaderName)!
    /// /health only: which app's secret the proof should use.
    static let aiiApp = HTTPField.Name(StackSecret.appHeaderName)!
}

/// A request context that carries the identity the stack secret named.
protocol StackCallerRequestContext: RequestContext {
    /// Set by StackSecretMiddleware: the identity whose secret the request
    /// presented on a shared stack — an app, or the stack itself (the aii
    /// command); nil on an open server.
    var callerIdentity: StackIdentity? { get set }
    /// The app among them; nil for the stack and on an open server.
    var callerApp: AIIApp? { get set }
}

extension StackMode {
    /// The whole local-mode check for one request, in HTTP terms: the identity it
    /// passes as, or the refusal to throw.
    func admittedIdentity(authority: String?, presented: String?) throws -> StackIdentity? {
        switch admit(authority: authority, presented: presented) {
        case .admitted(let identity):
            return identity
        case .notLoopback:
            throw HTTPError(.misdirectedRequest, message: "This server answers on loopback only")
        case .badSecret:
            throw HTTPError(.unauthorized, message: "Missing or wrong X-Ambient-Secret")
        }
    }

    /// The app it passes as: the stack identity passes as no app, since it has no
    /// lane and no chat.
    func admittedApp(authority: String?, presented: String?) throws -> AIIApp? {
        try admittedIdentity(authority: authority, presented: presented)?.app
    }
}

struct StackSecretMiddleware<Context: StackCallerRequestContext>: RouterMiddleware {
    let mode: StackMode

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        if request.uri.path == "/health" {
            return try await next(request, context)
        }
        var context = context
        let identity = try mode.admittedIdentity(
            authority: request.head.authority,
            presented: request.headers[.ambientSecret])
        context.callerIdentity = identity
        context.callerApp = identity?.app
        return try await next(request, context)
    }
}
