//
//  StackSecretMiddleware.swift
//  Thread
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The shared stack. When this Thread runs under a home (AII_HOME), every
//        request must carry one of the stack's secrets in X-Ambient-Secret and
//        address this machine by loopback.
//  IN:   StackMode.thread(environment:), decided once at start. Every identity's
//        secret is accepted, and the one that matched is recorded on the context
//        (`callerIdentity`) so each route cuts its work to that identity's lane.
//  OUT:  401 without a secret; 421 for a Host that isn't loopback
//  PIN:  Keeps web pages out. A page can't send a custom header cross-site
//        without a CORS preflight, and local mode answers none; a
//        DNS-rebinding page arrives under its own Host and never learns the
//        secret. /health stays open so a launcher can ask for proof of the
//        secret without sending it. The rules themselves live in AII,
//        shared with Sewn and every launcher.
//

import Foundation
import HTTPTypes
import Hummingbird
import AII

extension HTTPField.Name {
    static let ambientSecret = HTTPField.Name(StackSecret.headerName)!
    static let ambientNonce = HTTPField.Name(StackSecret.nonceHeaderName)!
    static let aiiApp = HTTPField.Name(StackSecret.appHeaderName)!
}

struct StackSecretMiddleware<Context: StackCallerContext>: RouterMiddleware {
    let mode: StackMode

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        if request.uri.path == "/health" {
            return try await next(request, context)
        }
        switch mode.admit(authority: request.head.authority, presented: request.headers[.ambientSecret]) {
        case .admitted(let identity):
            var context = context
            context.callerIdentity = identity
            return try await next(request, context)
        case .notLoopback:
            throw HTTPError(.misdirectedRequest, message: "This server answers on loopback only")
        case .badSecret:
            throw HTTPError(.unauthorized, message: "Missing or wrong X-Ambient-Secret")
        }
    }
}
