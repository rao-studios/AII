//
//  AIIHome+Provisioning.swift
//  AII
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Making ~/.rao exist, privately: the directories, the layout record, the stack's
//        secret, and the apps every home starts with (Ambient, Craft, Veil), each
//        registered with its secret, its lane and its record. The caller registers too.
//  IN:   Whichever app, server or aii command starts first; any later one, which finds
//        everything already there.
//  OUT:  0700 directories, layout.json, secrets/aii, and AIIHome.register for each app.
//  PIN:  Idempotent and race-safe: two provisioners at once end with one secret per
//        identity, because a secret is published with link(), which fails if the name
//        exists, and is never overwritten afterwards. The first provisioner writes the
//        Rao apps' secrets so Sewn and Thread, whoever starts them, know those apps before
//        they launch; any other app registers itself, and the servers admit it on their
//        keyring's next miss. Thread mints the stack secret itself too
//        (`ensureSecret(for: .stack)`), so a Thread started before any app ran still comes up.
//

import Foundation

public struct AIILayout: Codable, Sendable, Equatable {
    public var version: Int
    /// The app, or the stack (`aii`), that provisioned the home.
    public var createdBy: StackIdentity
    public var createdAt: Date

    public init(version: Int = AIIContract.layoutVersion, createdBy: StackIdentity, createdAt: Date) {
        self.version = version
        self.createdBy = createdBy
        self.createdAt = createdAt
    }
}

extension AIIHome {

    /// Creates whatever is missing, registers `app` (with `displayName` when it is new
    /// here; with `owner` as its lane's no-account owner when given) and returns every
    /// secret provisioning touched: the stack's, the Rao apps' and `app`'s.
    @discardableResult
    public func provision(by app: AIIApp, displayName: String? = nil, bundleIdentifier: String? = nil,
                          owner: AIIOwner? = nil, now: Date = Date()) throws -> [StackIdentity: String] {
        try provision(as: .app(app), displayName: displayName, bundleIdentifier: bundleIdentifier, owner: owner, now: now)
    }

    /// The same, as the stack itself (the aii command), which registers no app of its own.
    @discardableResult
    public func provision(now: Date = Date()) throws -> [StackIdentity: String] {
        try provision(as: .stack, displayName: nil, bundleIdentifier: nil, owner: nil, now: now)
    }

    private func provision(as identity: StackIdentity, displayName: String?, bundleIdentifier: String?,
                           owner: AIIOwner?, now: Date) throws -> [StackIdentity: String] {
        for directory in privateDirectories {
            try PrivateFile.ensureDirectory(directory)
        }
        if layout() == nil {
            let layout = AIILayout(createdBy: identity, createdAt: now)
            try PrivateFile.publishIfAbsent(try Self.encoder.encode(layout), to: layoutFile, mode: 0o600)
        }
        var secrets: [StackIdentity: String] = [.stack: try ensureSecret(for: .stack)]
        for app in AIIApp.allCases where identity != .app(app) {
            try register(app, by: identity, now: now)
            secrets[.app(app)] = try ensureSecret(for: app)
        }
        if case .app(let app) = identity {
            try register(app, displayName: displayName, bundleIdentifier: bundleIdentifier, owner: owner, by: identity, now: now)
            secrets[identity] = try ensureSecret(for: app)
        }
        try refuseSharedSecrets()
        return secrets
    }

    /// Throws when two identities on disk hold one value: that value can't say who it is.
    private func refuseSharedSecrets() throws {
        var byValue: [String: [StackIdentity]] = [:]
        for identity in [StackIdentity.stack] + registeredApps().map(StackIdentity.app) {
            if let secret = try readSecret(for: identity) { byValue[secret, default: []].append(identity) }
        }
        if let shared = byValue.values.first(where: { $0.count > 1 }) {
            throw AIIHomeError.duplicateSecret(shared.sorted())
        }
    }

    /// `identity`'s secret, publishing one first if none exists yet. Doesn't
    /// touch any other identity's.
    @discardableResult
    public func ensureSecret(for identity: StackIdentity) throws -> String {
        try PrivateFile.ensureDirectory(root)
        try PrivateFile.ensureDirectory(secretsDirectory)
        if let existing = try readSecret(for: identity) { return existing }
        let secret = StackSecret.generate()
        _ = try PrivateFile.publishIfAbsent(Data(secret.utf8), to: secretFile(for: identity), mode: 0o600)
        // Whoever won the race, the file now holds the one secret.
        guard let published = try readSecret(for: identity) else { throw AIIHomeError.missingSecret(identity) }
        return published
    }

    @discardableResult
    public func ensureSecret(for app: AIIApp) throws -> String { try ensureSecret(for: .app(app)) }

    /// `identity`'s secret, or nil when none has been published. Throws when the
    /// file is readable by others, owned by someone else, or not 64 hex.
    public func readSecret(for identity: StackIdentity) throws -> String? {
        let file = secretFile(for: identity)
        guard PrivateFile.exists(file) else { return nil }
        try PrivateFile.verifyPrivate(file)
        guard let data = FileManager.default.contents(atPath: PrivateFile.path(file)) else { return nil }
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard StackSecret.isWellFormedSecret(value) else { throw AIIHomeError.malformedSecret(identity) }
        return value.lowercased()
    }

    public func readSecret(for app: AIIApp) throws -> String? { try readSecret(for: .app(app)) }

    /// The layout file, if one was written.
    public func layout() -> AIILayout? {
        guard let data = FileManager.default.contents(atPath: PrivateFile.path(layoutFile)) else { return nil }
        return try? Self.decoder.decode(AIILayout.self, from: data)
    }

    /// Every directory provisioning creates, 0700. An app's own folder is made when it registers.
    public var privateDirectories: [URL] {
        [
            root, secretsDirectory, keysDirectory,
            aiiDirectory, aiiBinDirectory,
            sewnDataDirectory.deletingLastPathComponent(), sewnDataDirectory,
            threadDataDirectory.deletingLastPathComponent(), threadDataDirectory,
            aiiRunDirectory, aiiLeasesDirectory,
            appsDirectory, modelsDirectory,
        ]
    }

    // MARK: - Coding

    /// The files in a home are read by people too (`aii-lanes/1`, checkout paths): pretty,
    /// sorted, and with `/` unescaped.
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
