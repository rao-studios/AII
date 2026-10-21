//
//  Health.swift
//  Sewn
//
//  Created by Ritesh Pakala on 02/07/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: GET /health — liveness, and how a launcher tells this Sewn from
//        anything else on the port without ever sending a secret.
//  IN:   X-Ambient-Nonce (the challenge) and, on a shared stack, X-AII-App
//        (whose secret to prove).
//  OUT:  status/timestamp/stack/contract always; proof and app only when the
//        stack can make them (AII's `StackHealthAnswer`).
//

import Foundation
import Hummingbird
import AII

struct HealthResponse: Codable {
    let status: String
    let timestamp: String
    /// "proof" when this server holds a stack secret it can prove, "open"
    /// when it asks for none. How an app tells its own server from
    /// something else on the port, without ever sending the secret.
    let stack: String
    /// HMAC-SHA256 over the caller's X-Ambient-Nonce, keyed by the secret;
    /// absent unless a well-formed nonce came in and a secret is configured
    /// (on a shared stack: the secret of the app X-AII-App named).
    let proof: String?
    /// The app the proof is for; absent on an open server and when no proof
    /// could be made on a shared one.
    let app: String?
    /// The contract this build speaks.
    let contract: Int
}

func registerHealthRoute<Context: RequestContext>(_ router: some RouterMethods<Context>, stack: StackMode) {
    router.get("health") { request, _ async throws -> HealthResponse in
        let answer = stack.healthAnswer(
            nonce: request.headers[.ambientNonce],
            requestedApp: request.headers[.aiiApp])
        return HealthResponse(
            status: "healthy",
            timestamp: ISO8601DateFormatter().string(from: Date()),
            stack: answer.stack,
            proof: answer.proof,
            app: answer.app?.rawValue,
            contract: answer.contract
        )
    }
}
