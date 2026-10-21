//
//  StackChallenge.swift
//  AII
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The client half of /health: what to send, and what the answer says
//        about whoever holds the port.
//  IN:   A launcher's challenge (AIISupervisor, Veil's SewnClient, Craft's
//        stack reader).
//  OUT:  A verdict the launcher acts on: adopt, spawn, restart or refuse.
//  PIN:  The request carries a fresh nonce and the caller's name, never a
//        secret. Only a server that can read that identity's secret answers
//        with a proof that checks. A server that proves a different identity
//        than the one asked for is stale, not ours.
//

import Foundation

public enum StackVerdict: Equatable, Sendable {
    /// Nothing answered, or not with a 200.
    case down
    /// It proved it holds the identity's secret; `contract` is what it reports.
    case ours(contract: Int)
    /// It answered, but could not prove the secret: a server left from
    /// another launch or home, or something else holding the port.
    case stale
    /// It asks for no secret: a process started by hand with no AII_HOME.
    /// Never adopted.
    case open

    public var isOurs: Bool {
        if case .ours = self { return true }
        return false
    }
}

public enum StackChallenge {

    /// Headers for one /health challenge, as `identity` (an app, or the stack).
    public static func headers(nonce: String, identity: StackIdentity?) -> [String: String] {
        var headers = [StackSecret.nonceHeaderName: nonce]
        if let identity { headers[StackSecret.appHeaderName] = identity.rawValue }
        return headers
    }

    public static func headers(nonce: String, app: AIIApp?) -> [String: String] {
        headers(nonce: nonce, identity: app.map { .app($0) })
    }

    /// Reads a /health answer. `/health` says `"stack": "proof" | "open"`,
    /// and with a well-formed nonce `"proof": <hex>`, checked in constant
    /// time. A 200 that says none of this is something other than Sewn or
    /// Thread.
    public static func verdict(status: Int?, body: Data?, nonce: String, secret: String, expected: StackIdentity?) -> StackVerdict {
        guard status == 200 else { return .down }
        let object = body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        switch object?["stack"] as? String {
        case "open":
            return .open
        case "proof":
            guard StackSecret.isValidProof(object?["proof"] as? String, nonce: nonce, secret: secret) else { return .stale }
            if let expected, let named = object?["app"] as? String, named != expected.rawValue {
                return .stale
            }
            guard let contract = object?["contract"] as? Int else { return .stale }
            return .ours(contract: contract)
        default:
            return .stale
        }
    }

    public static func verdict(status: Int?, body: Data?, nonce: String, secret: String, expectedApp: AIIApp? = nil) -> StackVerdict {
        verdict(status: status, body: body, nonce: nonce, secret: secret, expected: expectedApp.map { .app($0) })
    }
}
