//
//  StackKeyring.swift
//  AII
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Every stack secret, as the shared Sewn and the one Thread hold them:
//        which identity a presented secret belongs to, and which secret to prove
//        for an identity.
//  IN:   AII_HOME/secrets/<identity>: every file there named like an app, and `aii`.
//        Read at start and again when a well-formed secret misses (an app registered
//        after the server started) or the ring is a minute old (a secret revoked by
//        deleting its file).
//  OUT:  StackMode.multiApp → the HTTP middleware, /health, the gRPC resolver.
//  PIN:  A presented value is compared against every entry, with no early
//        exit, so timing says nothing about which identity — or whether any —
//        matched. A file anyone else can read is skipped, not trusted. Two
//        identities with one value are both dropped: that value can't say who
//        it is. Reloads on a miss are throttled, so a stream of bad guesses
//        can't turn into a stream of file reads. A file whose name is neither an app
//        name nor `aii` is an issue, not an identity. The stack identity (`aii`) is
//        an entry like the apps': Thread presents it to Sewn, and a stack-wide
//        operation presents it to Thread.
//

import Foundation

public final class StackKeyring: @unchecked Sendable {

    public struct Issue: Sendable, Equatable, CustomStringConvertible {
        public let identity: StackIdentity?
        public let reason: String
        public var app: AIIApp? { identity?.app }
        public var description: String { identity.map { "\($0.rawValue): \(reason)" } ?? reason }
    }

    private let home: AIIHome?
    private let minimumReloadInterval: TimeInterval
    private let maximumAge: TimeInterval
    private let now: @Sendable () -> Date

    private let lock = NSLock()
    private var secrets: [StackIdentity: String] = [:]
    private var loadedAt: Date = .distantPast
    private var issues: [Issue] = []

    /// A ring read from `home`'s secrets directory.
    public init(
        home: AIIHome,
        minimumReloadInterval: TimeInterval = 2,
        maximumAge: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.home = home
        self.minimumReloadInterval = minimumReloadInterval
        self.maximumAge = maximumAge
        self.now = now
        reload()
    }

    /// A fixed ring, for tests: never reloads, and takes the values as given.
    public init(fixed: [StackIdentity: String]) {
        self.home = nil
        self.minimumReloadInterval = .infinity
        self.maximumAge = .infinity
        self.now = { Date() }
        self.secrets = fixed
        self.loadedAt = Date()
    }

    /// A fixed ring of app secrets only, for tests.
    public convenience init(fixed apps: [AIIApp: String]) {
        var byIdentity: [StackIdentity: String] = [:]
        for (app, secret) in apps { byIdentity[.app(app)] = secret }
        self.init(fixed: byIdentity)
    }

    // MARK: - Lookups

    /// The identity `presented` is the secret of, or nil.
    public func identity(forPresented presented: String?) -> StackIdentity? {
        guard let presented, !presented.isEmpty else { return nil }
        refreshIfOld()
        if let identity = match(presented) { return identity }
        // A secret published after the last read — an identity provisioned
        // while this server was running. Only a well-formed value earns a reload.
        guard StackSecret.isWellFormedSecret(presented), reloadIfAllowed() else { return nil }
        return match(presented)
    }

    /// The app `presented` is the secret of, or nil — nil too for the stack identity.
    public func app(forPresented presented: String?) -> AIIApp? {
        identity(forPresented: presented)?.app
    }

    /// `identity`'s secret, for proving it on /health; nil when it has none.
    public func secret(for identity: StackIdentity) -> String? {
        refreshIfOld()
        if let secret = lock.withLock({ secrets[identity] }) { return secret }
        guard reloadIfAllowed() else { return nil }
        return lock.withLock { secrets[identity] }
    }

    public func secret(for app: AIIApp) -> String? { secret(for: .app(app)) }

    /// Every identity with a secret, by name (so the stack first).
    public var provisionedIdentities: [StackIdentity] {
        lock.withLock { secrets.keys.sorted() }
    }

    public var provisionedApps: [AIIApp] { provisionedIdentities.compactMap(\.app) }

    public var lastIssues: [Issue] { lock.withLock { issues } }

    // MARK: - Loading

    /// Reads every identity's secret again. Returns what was skipped and why.
    @discardableResult
    public func reload() -> [Issue] {
        guard let home else { return [] }
        var loaded: [StackIdentity: String] = [:]
        var found: [Issue] = []
        let names = (try? FileManager.default.contentsOfDirectory(atPath: PrivateFile.path(home.secretsDirectory))) ?? []
        for name in names.sorted() where !name.hasPrefix(".") {
            guard let identity = StackIdentity(rawValue: name) else {
                found.append(Issue(identity: nil, reason: "secrets/\(name) is not an app name"))
                continue
            }
            do {
                if let secret = try home.readSecret(for: identity) { loaded[identity] = secret }
            } catch {
                found.append(Issue(identity: identity, reason: "\(error)"))
            }
        }
        let byValue = Dictionary(grouping: loaded.keys, by: { loaded[$0]! })
        for identities in byValue.values where identities.count > 1 {
            for identity in identities { loaded[identity] = nil }
            found.append(Issue(identity: nil, reason: "\(identities.map(\.rawValue).sorted().joined(separator: ", ")) share one secret; none of them is accepted"))
        }
        let stamp = now()
        lock.withLock {
            secrets = loaded
            issues = found
            loadedAt = stamp
        }
        return found
    }

    private func match(_ presented: String) -> StackIdentity? {
        let entries = lock.withLock { secrets }
        var found: StackIdentity?
        for (identity, secret) in entries {
            // Every entry is compared, match or not.
            if StackSecret.matches(presented, secret: secret) { found = identity }
        }
        return found
    }

    private func refreshIfOld() {
        guard home != nil else { return }
        let age = now().timeIntervalSince(lock.withLock { loadedAt })
        if age >= maximumAge { reload() }
    }

    /// Reloads unless one happened within the throttle; true when it did.
    private func reloadIfAllowed() -> Bool {
        guard home != nil else { return false }
        let age = now().timeIntervalSince(lock.withLock { loadedAt })
        guard age >= minimumReloadInterval else { return false }
        reload()
        return true
    }
}
