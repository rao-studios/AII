//
//  StackProbe.swift
//  AII
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: One /health challenge over the network: a fresh nonce and the caller's
//        name out, a verdict back — and the body, for what else /health says
//        (Thread's embedder).
//  PIN:  Never sends a secret. Loopback only, no proxy, no cache, no cookies.
//

#if os(macOS)
import Foundation

public enum StackProbe {

    public static func challenge(_ spec: LaunchSpec, secret: String, timeout: TimeInterval = 2) async -> StackVerdict {
        await challengeWithBody(spec, secret: secret, timeout: timeout).verdict
    }

    /// The verdict and the answer it was read from (nil when nothing answered).
    public static func challengeWithBody(_ spec: LaunchSpec, secret: String, timeout: TimeInterval = 2) async -> (verdict: StackVerdict, body: Data?) {
        await challengeWithBody(url: spec.healthURL, secret: secret, identity: spec.challenge, timeout: timeout)
    }

    public static func challenge(url: URL, secret: String, app: AIIApp?, timeout: TimeInterval = 2) async -> StackVerdict {
        await challengeWithBody(url: url, secret: secret, identity: app.map { .app($0) }, timeout: timeout).verdict
    }

    public static func challengeWithBody(url: URL, secret: String, identity: StackIdentity?, timeout: TimeInterval = 2) async -> (verdict: StackVerdict, body: Data?) {
        let nonce = StackSecret.nonce()
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in StackChallenge.headers(nonce: nonce, identity: identity) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            return (StackChallenge.verdict(status: status, body: data, nonce: nonce, secret: secret, expected: identity), data)
        } catch {
            return (.down, nil)
        }
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 5
        return URLSession(configuration: configuration)
    }()
}
#endif
