//
//  SewnRequestContext.swift
//  Sewn
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//

import Hummingbird
import NIOCore
import AII

/// Custom request context for Sewn.
///
/// - Stores auth fields populated by `AuthMiddleware` / `AdminMiddleware`
///   (replaces the Vapor `Request.storage` extension pattern), including
///   `isLocalOnly` for the on-device lane a local app reaches with no account.
/// - Stores the calling app populated by `StackSecretMiddleware`, which every
///   Thread fan-out is scoped by on a shared stack.
/// - Overrides the 2 MB default `maxUploadSize` to 100 MB for large
///   embedding / document payloads.
/// - Conforms to `RemoteAddressRequestContext` so middleware can inspect
///   the client's socket address via `context.remoteAddress`.
struct SewnRequestContext: RequestContext, RemoteAddressRequestContext, StackCallerRequestContext {
    var coreContext: CoreRequestContextStorage

    // MARK: - Remote address (captured at init from the NIO channel)

    var remoteAddress: SocketAddress?

    // MARK: - Auth (populated by AuthMiddleware / AdminMiddleware)

    var authUserId: String?
    var authToken: String?
    var authDisplayName: String?
    /// True when AuthMiddleware admitted this request without a bearer: a
    /// caller the stack secret named (loopback, secret verified) running the
    /// on-device lane with no account. `authUserId` is then
    /// `LocalOnlyGrant.ownerId(for: callerApp)` and `authToken` is nil. Every
    /// generation route refuses a hosted provider for such a caller.
    var isLocalOnly: Bool = false

    // MARK: - Stack (populated by StackSecretMiddleware)

    /// The identity whose stack secret this request carried: an app, or the stack
    /// (the aii command). Nil on an open server.
    var callerIdentity: StackIdentity?
    /// The app whose stack secret this request carried. Nil for the stack and on an
    /// open server.
    var callerApp: AIIApp?

    // MARK: - Init

    init(source: ApplicationRequestContextSource) {
        self.coreContext = .init(source: source)
        self.remoteAddress = source.channel.remoteAddress
    }

    // MARK: - Upload limit

    var maxUploadSize: Int { 100 * 1_024 * 1_024 }
}
