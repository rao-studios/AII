//
//  StackMode.swift
//  AII
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: How a server tells who is calling. Under AII_HOME it is `multiApp`: every
//        identity's secret from the home's keyring, lanes by the secret that matched.
//        Without AII_HOME it is `open`: a process started by hand or by a test, which
//        asks for no secret and is never adopted by a launcher.
//  PIN:  Under AII_HOME a server never comes up open. There is no single-secret mode:
//        the supervisor is the only launcher, and it always sets AII_HOME.
//

import Foundation

public enum StackMode: Sendable {
    case open
    case multiApp(StackKeyring)

    // MARK: - From the environment

    /// Sewn's mode: AII_HOME → multiApp; else open. Throws for an AII_HOME that isn't usable.
    public static func sewn(environment: [String: String]) throws -> StackMode {
        try shared(environment: environment)
    }

    /// A Thread's mode: the same rule as Sewn's. AII_HOME → multiApp (every identity's
    /// secret, lanes by the secret that matched); else open.
    public static func thread(environment: [String: String]) throws -> StackMode {
        try shared(environment: environment)
    }

    private static func shared(environment: [String: String]) throws -> StackMode {
        if let home = try AIIHome.fromEnvironment(environment) {
            guard PrivateFile.exists(home.root) else { throw AIIHomeError.missing(PrivateFile.path(home.root)) }
            try PrivateFile.verifyPrivate(home.root)
            return .multiApp(StackKeyring(home: home))
        }
        return .open
    }

    // MARK: - Facts

    /// Any secret at all: loopback only, secret required, no CORS.
    public var isLocal: Bool {
        if case .open = self { return false }
        return true
    }

    public var keyring: StackKeyring? {
        if case .multiApp(let keyring) = self { return keyring }
        return nil
    }

    /// For Seam's `StackSecretServerInterceptor(resolver:)` and
    /// `ThreadRegistrationServiceImpl(callerResolver:)`: presented secret →
    /// identity id (`ambient`, `craft`, `veil`, `aii`). Nil unless multiApp.
    public var grpcResolver: (@Sendable (String) -> String?)? {
        guard case .multiApp(let keyring) = self else { return nil }
        return { presented in keyring.identity(forPresented: presented)?.rawValue }
    }

    /// One line for the startup log. Never a secret.
    public var summary: String {
        switch self {
        case .open:
            return "open (no stack secret)"
        case .multiApp(let keyring):
            let identities = keyring.provisionedIdentities.map(\.rawValue).joined(separator: ", ")
            return "shared, one secret per identity (\(identities.isEmpty ? "none provisioned yet" : identities))"
        }
    }

    // MARK: - Per request

    /// Whether a request may pass, and as whom. /health is not asked.
    public func admit(authority: String?, presented: String?) -> StackAdmission {
        switch self {
        case .open:
            return .admitted(nil)
        case .multiApp(let keyring):
            guard StackSecret.isLoopback(authority: authority) else { return .notLoopback }
            guard let identity = keyring.identity(forPresented: presented) else { return .badSecret }
            return .admitted(identity)
        }
    }

    /// What /health answers. The secret itself never answers; a proof needs a
    /// well-formed nonce and, on the shared stack, an identity it knows (the
    /// X-AII-App header: an app's name, or `aii`). Every answer carries this
    /// build's contract.
    public func healthAnswer(nonce: String?, requestedApp: String?) -> StackHealthAnswer {
        switch self {
        case .open:
            return StackHealthAnswer(stack: "open", proof: nil, app: nil, contract: AIIContract.version)
        case .multiApp(let keyring):
            guard let nonce, StackSecret.isWellFormedNonce(nonce),
                  let identity = StackIdentity(header: requestedApp),
                  let secret = keyring.secret(for: identity) else {
                return StackHealthAnswer(stack: "proof", proof: nil, app: nil, contract: AIIContract.version)
            }
            return StackHealthAnswer(stack: "proof", proof: StackSecret.proof(nonce: nonce, secret: secret),
                                     app: identity, contract: AIIContract.version)
        }
    }

}

public enum StackAdmission: Sendable, Equatable {
    /// Pass. The identity is known on the shared stack; nil when open.
    case admitted(StackIdentity?)
    /// 421: the Host isn't this machine.
    case notLoopback
    /// 401: no secret, or not one this server knows.
    case badSecret

    public var identity: StackIdentity? {
        if case .admitted(let identity) = self { return identity }
        return nil
    }

    /// The app that called, when an app did. Nil when open, and nil for the
    /// stack identity — which is not an app and has no lane.
    public var app: AIIApp? { identity?.app }

    public var isStack: Bool { identity?.isStack ?? false }
}

/// /health's stack fields. `proof` and `app` are left out of the JSON when nil.
/// `app` carries the identity's name (`ambient`, …, or `aii`); `contract` is
/// always this build's.
public struct StackHealthAnswer: Sendable, Equatable, Codable {
    public let stack: String
    public let proof: String?
    public let app: StackIdentity?
    public let contract: Int

    public init(stack: String, proof: String?, app: StackIdentity?, contract: Int) {
        self.stack = stack
        self.proof = proof
        self.app = app
        self.contract = contract
    }
}
