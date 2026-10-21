//
//  ProviderKeyStore.swift
//  AII
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The provider keys (Mistral, Tinker) every Rao app's stack shares:
//        AII_HOME/keys/providers.json, one record per key naming its value,
//        where it came from and who wrote it.
//  IN:   Writes: the app the user typed the key into (Ambient's Settings
//        projects its Keychain here), and the aii command (`aii keys set`,
//        `aii setup` and `aii install`, from a checkout's .env). Reads: Sewn and
//        every Thread, on every call to a provider.
//  OUT:  `value(for:)` — the file's value when it has one, else the process
//        environment (a dev checkout's .env, a hosted deployment's secrets).
//  PIN:  Read per call and cached by the file's identity (inode, size, mtime),
//        so a key saved in Ambient reaches a shared Sewn and every Thread on
//        their next request, with nothing restarted. The file is 0600 and
//        written atomically under a lock, so apps writing different keys at
//        once both survive. A server only reads the file when its launcher set
//        AII_HOME (`process`), so hosted deployments are unchanged. A record's
//        writer is a `StackIdentity`: an app, or the stack (`aii`); on disk it
//        is the same plain string an app always wrote.
//

import Foundation

public struct ProviderKeyRecord: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable {
        /// The user typed it into an app, or gave it to the aii command.
        case typed
        /// The user's account handed it over (Sewn's /v1/account/keys).
        case account
    }

    public var value: String
    public var source: Source
    public var writtenBy: StackIdentity
    public var updatedAt: Date

    public init(value: String, source: Source, writtenBy: StackIdentity, updatedAt: Date) {
        self.value = value
        self.source = source
        self.writtenBy = writtenBy
        self.updatedAt = updatedAt
    }

    /// An app's record: `writtenBy: .ambient` reads as it always did.
    public init(value: String, source: Source, writtenBy app: AIIApp, updatedAt: Date) {
        self.init(value: value, source: source, writtenBy: .app(app), updatedAt: updatedAt)
    }
}

public enum ProviderKeyStoreError: Error, Equatable, CustomStringConvertible {
    /// The file holds bytes that don't decode: both servers read it as no keys.
    case malformed(String)

    public var description: String {
        switch self {
        case .malformed(let path): return "\(path) doesn't decode; both servers read it as no keys"
        }
    }
}

public final class ProviderKeyStore: @unchecked Sendable {
    public static let mistralAPIKey = "MISTRAL_API_KEY"
    public static let tinkerAPIKey = "TINKER_API_KEY"

    /// The keys a checkout's .env may hand to the shared file, and the ones
    /// aii.env refuses for the same reason: they have this home.
    public static let sharedKeyNames: Set<String> = [mistralAPIKey, tinkerAPIKey]

    /// A server's store: backed by AII_HOME's file when its launcher set
    /// AII_HOME, otherwise the environment alone.
    public static let process = ProviderKeyStore(home: try? AIIHome.fromEnvironment())

    public let file: URL?
    private let lockFile: URL?
    private let environment: @Sendable () -> [String: String]

    private let lock = NSLock()
    private var cachedIdentity: FileIdentity?
    private var cachedRecords: [String: ProviderKeyRecord] = [:]

    public init(
        file: URL?,
        lockFile: URL? = nil,
        environment: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment }
    ) {
        self.file = file
        self.lockFile = lockFile ?? file.map { $0.deletingLastPathComponent().appendingPathComponent(".providers.lock") }
        self.environment = environment
    }

    public convenience init(
        home: AIIHome?,
        environment: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment }
    ) {
        self.init(file: home?.providersFile, lockFile: home?.providersLockFile, environment: environment)
    }

    public var isFileBacked: Bool { file != nil }

    /// Those of the shared keys with a non-empty value in an env file: what a
    /// checkout's .env hands to the stack.
    public static func sharedKeys(inEnvFile url: URL) -> [String: String] {
        EnvFile.read(url).filter { sharedKeyNames.contains($0.key) && !$0.value.isEmpty }
    }

    // MARK: - Reading

    /// The key to use now: the shared file's non-empty value, else the
    /// environment's non-empty value, else nil.
    public func value(for name: String) -> String? {
        if let record = record(for: name), !record.value.isEmpty { return record.value }
        if let value = environment()[name], !value.isEmpty { return value }
        return nil
    }

    public func record(for name: String) -> ProviderKeyRecord? {
        records()[name]
    }

    /// Every record in the shared file (empty without one, or when it doesn't
    /// decode: a server never fails on it).
    public func records() -> [String: ProviderKeyRecord] {
        guard let file else { return [:] }
        let identity = PrivateFile.identity(file)
        return lock.withLock {
            if identity == cachedIdentity { return cachedRecords }
            cachedIdentity = identity
            cachedRecords = identity == nil ? [:] : Self.decode(file)
            return cachedRecords
        }
    }

    /// Every record, or the reason there are none: the doctor's view. Throws
    /// `ProviderKeyStoreError.malformed` for a file with bytes that don't decode
    /// and `PrivateFileError` for one that is open to others.
    public func checkedRecords() throws -> [String: ProviderKeyRecord] {
        guard let file, PrivateFile.exists(file) else { return [:] }
        try PrivateFile.verifyPrivate(file)
        guard let data = FileManager.default.contents(atPath: PrivateFile.path(file)), !data.isEmpty else { return [:] }
        do {
            return try AIIHome.decoder.decode([String: ProviderKeyRecord].self, from: data)
        } catch {
            throw ProviderKeyStoreError.malformed(PrivateFile.path(file))
        }
    }

    // MARK: - Writing

    /// Sets `name`, keeping every other key as it is.
    public func write(_ name: String, value: String, source: ProviderKeyRecord.Source, writtenBy: StackIdentity, now: Date = Date()) throws {
        try update { records in
            records[name] = ProviderKeyRecord(value: value, source: source, writtenBy: writtenBy, updatedAt: now)
        }
    }

    /// An app setting `name`.
    public func write(_ name: String, value: String, source: ProviderKeyRecord.Source, writtenBy app: AIIApp, now: Date = Date()) throws {
        try write(name, value: value, source: source, writtenBy: .app(app), now: now)
    }

    /// Removes `name`, keeping every other key as it is.
    public func remove(_ name: String) throws {
        try update { records in records[name] = nil }
    }

    /// What `adopt` did with each key it was given.
    public enum Adoption: String, Sendable, Equatable {
        /// Written: new, or a changed typed value.
        case set
        /// The same value was already there; the record is untouched.
        case alreadySet
        /// An account handed the key over; a checkout's value never replaces it.
        case keptAccount
    }

    /// `aii setup` and `aii install`: a checkout's keys into the file as typed values
    /// of the stack's. A new or changed typed value is written, the same value left as
    /// it is, a key the person's account handed over kept: that is their plan's key,
    /// and a checkout's .env must not reroute it on every `aii update`. Empty values and
    /// names outside `sharedKeyNames` are ignored; nothing is removed. One lock, one
    /// write. Nothing happens without a file.
    @discardableResult
    public func adopt(_ keys: [String: String], writtenBy: StackIdentity = .stack, now: Date = Date()) throws -> [String: Adoption] {
        guard isFileBacked else { return [:] }
        let wanted = keys.filter { Self.sharedKeyNames.contains($0.key) && !$0.value.isEmpty }
        guard !wanted.isEmpty else { return [:] }
        var outcome: [String: Adoption] = [:]
        try update { records in
            for (name, value) in wanted {
                if let existing = records[name] {
                    if existing.source == .account, !existing.value.isEmpty {
                        outcome[name] = .keptAccount
                        continue
                    }
                    if existing.value == value {
                        outcome[name] = .alreadySet
                        continue
                    }
                }
                records[name] = ProviderKeyRecord(value: value, source: .typed, writtenBy: writtenBy, updatedAt: now)
                outcome[name] = .set
            }
        }
        return outcome
    }

    /// Read-modify-write under the lock: the change applies to whatever the
    /// file holds at that moment, not to what this process last read.
    public func update(_ change: (inout [String: ProviderKeyRecord]) -> Void) throws {
        guard let file, let lockFile else { return }
        try PrivateFile.ensureDirectory(file.deletingLastPathComponent())
        try PrivateFile.withExclusiveLock(lockFile) {
            var records = Self.decode(file)
            let before = records
            change(&records)
            guard records != before else { return }
            try PrivateFile.writeAtomically(try AIIHome.encoder.encode(records), to: file, mode: 0o600)
        }
        lock.withLock { cachedIdentity = nil }
    }

    private static func decode(_ file: URL) -> [String: ProviderKeyRecord] {
        guard let data = FileManager.default.contents(atPath: PrivateFile.path(file)), !data.isEmpty else { return [:] }
        return (try? AIIHome.decoder.decode([String: ProviderKeyRecord].self, from: data)) ?? [:]
    }
}
