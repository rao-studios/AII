//
//  StackSecretInterceptors.swift
//  Seam
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The gRPC half of the stack contract. A mothership on the shared stack
//        answers only RPCs that carry one of the stack's secrets in
//        x-ambient-secret and arrive over loopback; the Thread it serves stamps
//        its secret on every RPC it sends.
//  IN:   Sewn knows every identity's secret (AII's StackKeyring) and hands a
//        resolver (presented secret → identity id) to `forLocalMode(resolver:)`,
//        so the one mothership accepts the one Thread and knows the identity it
//        speaks as. Thread hands the stack's secret to
//        `StackSecretClientInterceptor`. Hosted deployments set nothing and get
//        no interceptor — nothing here changes for them.
//  OUT:  PERMISSION_DENIED for a peer that isn't loopback; UNAUTHENTICATED
//        without a secret the server knows. The HTTP side of the same
//        contract is X-Ambient-Secret in Sewn/Thread's StackSecretMiddleware.
//  PIN:  A refusal is logged with the method and the peer, never the
//        presented value — a wrong guess in a log line is still a secret.
//        The compare is constant-time so a wrong guess learns nothing from
//        how long it took.
//

import Foundation
import GRPCCore

/// Maps a presented stack secret to the app it belongs to — `"ambient"`,
/// `"craft"`, `"veil"` — or nil when it is no app's secret. A shared stack's
/// mothership builds one from the keyring in ~/.rao (AII's `StackMode`);
/// Conduit only needs the answer, never the secrets themselves.
public typealias StackSecretResolver = @Sendable (_ presented: String) -> String?

/// The metadata key both halves agree on, and the checks the server applies.
public enum StackSecretMetadata {

    /// gRPC metadata keys are lowercase on the wire; this is the HTTP header
    /// `X-Ambient-Secret` as gRPC spells it.
    public static let key = "x-ambient-secret"

    /// The first `x-ambient-secret` value on the request, if any.
    public static func presented(in metadata: Metadata) -> String? {
        var values = metadata[stringValues: key].makeIterator()
        return values.next()
    }

    /// The app whose secret `metadata` presents, per `resolver`; nil when the
    /// request carries no secret or one no app owns.
    public static func callerApp(in metadata: Metadata, resolver: StackSecretResolver) -> String? {
        guard let presented = presented(in: metadata), !presented.isEmpty else { return nil }
        return resolver(presented)
    }

    /// Whether `peer` (a `ServerContext.remotePeer` string) is this machine:
    /// `ipv4:127.x.x.x:port`, `ipv6:[::1]:port`, an IPv4-mapped loopback,
    /// a Unix socket, or grpc-swift's in-process transport.
    public static func isLoopbackPeer(_ peer: String) -> Bool {
        loopbackPeerPrefixes.contains { peer.hasPrefix($0) }
    }

    private static let loopbackPeerPrefixes = [
        "ipv4:127.",
        "ipv6:[::1]:",
        "ipv6:[::ffff:127.",
        "unix:",
        "in-process:",
    ]
}

// MARK: - Server side

/// Refuses every RPC that doesn't carry a stack secret the server knows, from
/// a loopback peer. Install on the mothership's `GRPCServer`
/// (``SeamMothershipServer`` takes it through `interceptors:`); build it with
/// ``forLocalMode(resolver:logger:)`` so a deployment without a stack gets no
/// interceptor at all.
public struct StackSecretServerInterceptor: ServerInterceptor {

    private let resolver: StackSecretResolver
    private let requireLoopbackPeer: Bool
    private let logger: (any SeamLogger)?

    /// - Parameters:
    ///   - resolver: Presented secret → identity id, or nil for no identity's secret.
    ///   - requireLoopbackPeer: Also refuse peers that aren't this machine.
    ///     On by default — the local stack has no business answering the LAN.
    ///   - logger: Where refusals are noted (method and peer, never the value).
    public init(resolver: @escaping StackSecretResolver, requireLoopbackPeer: Bool = true, logger: (any SeamLogger)? = nil) {
        self.resolver = resolver
        self.requireLoopbackPeer = requireLoopbackPeer
        self.logger = logger
    }

    /// The interceptor list for a stack's mothership: one interceptor when a
    /// resolver is given, none when it is nil (an open server).
    public static func forLocalMode(resolver: StackSecretResolver?, logger: (any SeamLogger)? = nil) -> [any ServerInterceptor] {
        guard let resolver else { return [] }
        return [StackSecretServerInterceptor(resolver: resolver, logger: logger)]
    }

    public func intercept<Input: Sendable, Output: Sendable>(
        request: StreamingServerRequest<Input>,
        context: ServerContext,
        next: @Sendable (StreamingServerRequest<Input>, ServerContext) async throws -> StreamingServerResponse<Output>
    ) async throws -> StreamingServerResponse<Output> {
        let method = context.descriptor.fullyQualifiedMethod
        let peer = context.remotePeer

        if requireLoopbackPeer, !StackSecretMetadata.isLoopbackPeer(peer) {
            logger?.warning("StackSecret: refused \(method) from \(peer) — not a loopback peer")
            throw RPCError(code: .permissionDenied, message: "This server answers on loopback only")
        }

        let presented = StackSecretMetadata.presented(in: request.metadata)
        guard let presented, !presented.isEmpty, resolver(presented) != nil else {
            logger?.warning("StackSecret: refused \(method) from \(peer) — missing or unknown \(StackSecretMetadata.key)")
            throw RPCError(code: .unauthenticated, message: "Missing or unknown x-ambient-secret")
        }

        return try await next(request, context)
    }
}

// MARK: - Client side

/// Stamps the stack secret onto every RPC. Install on the Thread's client
/// (``MothershipRegistrationClient`` takes it through `interceptors:`). With
/// no secret to present it passes requests through untouched, so it is safe
/// to install unconditionally and let the closure decide.
public struct StackSecretClientInterceptor: ClientInterceptor {

    private let secret: @Sendable () -> String?

    /// - Parameter secret: Read on every RPC; nil or empty means "add nothing".
    public init(secret: @escaping @Sendable () -> String?) {
        self.secret = secret
    }

    /// A fixed secret, e.g. the stack secret a Thread read from the keyring at launch.
    public init(secret: String) {
        self.init(secret: { secret })
    }

    public func intercept<Input: Sendable, Output: Sendable>(
        request: StreamingClientRequest<Input>,
        context: ClientContext,
        next: (StreamingClientRequest<Input>, ClientContext) async throws -> StreamingClientResponse<Output>
    ) async throws -> StreamingClientResponse<Output> {
        guard let value = secret(), !value.isEmpty else {
            return try await next(request, context)
        }
        var request = request
        request.metadata.replaceOrAddString(value, forKey: StackSecretMetadata.key)
        return try await next(request, context)
    }
}
