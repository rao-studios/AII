//
//  AuthMiddleware.swift
//  Sewn
//
//  Created by Ritesh Pakala on 02/23/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The protected tree's gate. A Supabase bearer names the account;
//        with none, a caller the stack secret named may take the on-device
//        lane on LocalOnlyGrant's routes only.
//  IN:   Authorization: Bearer <access_token>; context.callerApp from
//        StackSecretMiddleware; context.endpointPath from the router.
//  OUT:  context.authUserId / authToken / authDisplayName for an account;
//        authUserId = the lane's owner ("local-<app>" or "aii-local"; "aii-local"
//        for the stack), authToken nil, isLocalOnly = true for the grant; 401
//        otherwise.
//  PIN:  A presented token is always validated: a bad bearer is 401 even on
//        a granted route, never a quiet downgrade. An open server (callerApp
//        nil) grants nothing. The validator is injectable so tests never
//        reach Supabase.
//

import AII
import Foundation
import Supabase
import Hummingbird

// MARK: - Middleware

struct AuthMiddleware: RouterMiddleware {
    typealias Context = SewnRequestContext
    typealias Validate = @Sendable (String) async throws -> TokenValidator.ValidatedUser

    /// Supabase in production. Never consulted when no header came.
    var validate: Validate = { try await TokenValidator.validate($0) }
    /// A no-account app's owner: its lane's in the manifest (SewnServer passes the lane
    /// registry's `owner(for:)`). Without one, each app answers as its own `local-<app>`.
    var laneOwner: @Sendable (AIIApp) -> AIIOwner = { .app($0) }

    func handle(
        _ request: Request,
        context: SewnRequestContext,
        next: (Request, SewnRequestContext) async throws -> Response
    ) async throws -> Response {
        guard let authHeader = request.headers[.authorization] else {
            // No token at all, not a bad one. The stack secret already named
            // the caller; on the granted routes that is identity enough for
            // the on-device lane.
            if let identity = context.callerIdentity,
               LocalOnlyGrant.admits(identity, method: request.method, endpointPath: context.endpointPath) {
                var ctx = context
                ctx.authUserId = LocalOnlyGrant.ownerId(for: identity, laneOwner: laneOwner)
                ctx.authToken = nil
                ctx.authDisplayName = nil
                ctx.isLocalOnly = true
                return try await next(request, ctx)
            }
            throw Hummingbird.HTTPError(.unauthorized, message: "Missing Authorization: Bearer token")
        }
        guard authHeader.hasPrefix("Bearer "), !authHeader.dropFirst(7).isEmpty else {
            throw Hummingbird.HTTPError(.unauthorized, message: "Missing Authorization: Bearer token")
        }
        let token = String(authHeader.dropFirst(7))

        let user = try await validate(token)
        var ctx = context
        ctx.authUserId = user.userId
        ctx.authToken = token
        ctx.authDisplayName = user.displayName
        ctx.isLocalOnly = false
        return try await next(request, ctx)
    }
}
