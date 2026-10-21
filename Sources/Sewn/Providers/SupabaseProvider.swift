//
//  SupabaseProvider.swift
//  Sewn
//
//  Created by Ritesh Pakala on 02/22/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The Supabase client the auth routes share, and the one answer when the
//        accounts layer isn't configured: 503, never a crash.
//  IN:   SUPABASE_URL and SUPABASE_ANON_KEY, from the environment (aii/aii.env
//        on a shared stack, a hosted deployment's secrets, a checkout's .env).
//  PIN:  An app indexing its own data needs no Supabase: with the stack's secret
//        it never reaches these routes. So a missing project is a state, not a
//        fault. `shared` throws the 503 instead of `fatalError`, and the six auth
//        routes carry it through their `try await`.
//

import Foundation
import Supabase
import Hummingbird

/// Thread-safe in-memory implementation of ``AuthLocalStorage``.
/// Used on Linux (and any platform without Keychain/WinCred) where no
/// platform-provided credential store is available.
final class InMemoryLocalStorage: AuthLocalStorage, @unchecked Sendable {
    private var store: [String: Data] = [:]
    private let lock = NSLock()

    func store(key: String, value: Data) throws {
        lock.withLock { store[key] = value }
    }

    func retrieve(key: String) throws -> Data? {
        lock.withLock { store[key] }
    }

    func remove(key: String) throws {
        lock.withLock { _ = store.removeValue(forKey: key) }
    }
}

/// Shared Supabase client for stateless auth operations (sign-up, sign-in,
/// verify, refresh, reset-password). All of these pass tokens explicitly and
/// do not depend on stored session state, so a single instance is safe for
/// concurrent requests.
///
/// For sign-out — which requires an active session to be set on the client —
/// use `SupabaseProvider.makeClient()` to obtain a per-request instance.
enum SupabaseProvider {
    /// What the auth routes need: both values non-empty, the URL absolute.
    struct Configuration: Equatable, Sendable {
        let url: URL
        let anonKey: String
    }

    /// The project from `environment`, or nil when the accounts layer isn't configured.
    /// An empty value is unset (a copied .env.example ships `KEY=` lines); a URL with no
    /// scheme is no URL.
    static func configuration(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Configuration? {
        guard let urlString = environment["SUPABASE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines), !urlString.isEmpty,
              let url = URL(string: urlString), let scheme = url.scheme, !scheme.isEmpty, url.host != nil,
              let key = environment["SUPABASE_ANON_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty
        else { return nil }
        return Configuration(url: url, anonKey: key)
    }

    /// Every auth route's answer without a project. Never a crash.
    static var notConfigured: Hummingbird.HTTPError { Hummingbird.HTTPError(.serviceUnavailable, message: "Auth service not configured") }

    private static let configured: SupabaseClient? = configuration().map(client)

    /// The shared client for stateless auth calls; the 503 when unconfigured.
    static var shared: SupabaseClient {
        get throws {
            guard let configured else { throw notConfigured }
            return configured
        }
    }

    /// Creates a fresh client for operations that require setting session state
    /// (e.g. sign-out). Throws the 503 when the project isn't configured.
    static func makeClient() throws -> SupabaseClient {
        guard let configuration = configuration() else { throw notConfigured }
        return client(configuration)
    }

    private static func client(_ configuration: Configuration) -> SupabaseClient {
        SupabaseClient(
            supabaseURL: configuration.url,
            supabaseKey: configuration.anonKey,
            options: SupabaseClientOptions(
                auth: .init(storage: InMemoryLocalStorage())
            )
        )
    }
}
