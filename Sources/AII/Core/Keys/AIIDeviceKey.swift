//
//  AIIDeviceKey.swift
//  AII
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The one key this Mac keys things with: 32 random bytes in
//        ~/.rao/keys/device.key, 64 hex digits, mode 0600. Veil's one-way tile
//        serializer draws its measurement weights from it; the lanes of the index
//        were registered from it (AIILane). It never leaves this machine and never
//        enters a policy, a report or a log — only its fingerprint does.
//  IN:   Veil (tiles), the lane registration, anything else that needs a secret
//        that is the device's rather than an app's.
//  OUT:  HMAC-keyed derivations under a label, a counter-mode byte stream, a
//        fingerprint; kept keys beside it.
//  PIN:  A key is never thrown away. Regenerating moves the current one aside as
//        `device-<fingerprint>.key` before the new one is written, and any kept key
//        can be made current again — the only way back to a corpus written with it.
//        The fingerprint is HMAC-SHA256(key, "veil.key.fingerprint"), first four bytes:
//        the formula Veil's corpora name their key by.
//

import Crypto
import Foundation

public struct AIIDeviceKey: Sendable, Equatable, CustomStringConvertible {
    public static let byteCount = 32
    public static let fileName = "device.key"
    static let fingerprintLabel = "veil.key.fingerprint"

    let bytes: [UInt8]

    /// Nil unless exactly `byteCount` bytes.
    public init?(bytes: [UInt8]) {
        guard bytes.count == Self.byteCount else { return nil }
        self.bytes = bytes
    }

    /// 64 hex digits, surrounding whitespace ignored.
    public init?(hex: String) {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count == Self.byteCount * 2, let bytes = StackSecret.hexBytes(trimmed) else { return nil }
        self.bytes = bytes
    }

    public static func random() -> AIIDeviceKey {
        var generator = SystemRandomNumberGenerator()
        return AIIDeviceKey(bytes: (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) })!
    }

    /// Eight hex digits that name the key without revealing it.
    public var fingerprint: String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(Self.fingerprintLabel.utf8), using: SymmetricKey(data: bytes))
        return StackSecret.hex(Array(mac.prefix(4)))
    }

    /// Never the key.
    public var description: String { "AIIDeviceKey(\(fingerprint))" }

    var hex: String { StackSecret.hex(bytes) }

    // MARK: - Derivations

    /// HMAC-SHA256(key, label ‖ message): a tag for `message` under a purpose.
    public func mac(label: String, message: Data) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(for: Data(label.utf8) + message, using: SymmetricKey(data: bytes)))
    }

    /// A key for one purpose, derived under `label`; the device key itself is
    /// never handed out.
    public func derive(label: String) -> SymmetricKey {
        SymmetricKey(data: Data(mac(label: label, message: Data())))
    }

    /// A deterministic byte stream for one purpose: block `n` is
    /// `HMAC-SHA256(key, label ‖ n as 4 big-endian bytes)`.
    public func stream(_ label: String) -> KeyStream { KeyStream(key: SymmetricKey(data: bytes), label: Array(label.utf8)) }

    public struct KeyStream {
        private let key: SymmetricKey
        private let label: [UInt8]
        private var counter: UInt32 = 0
        private var block: [UInt8] = []
        private var offset = 0

        init(key: SymmetricKey, label: [UInt8]) {
            self.key = key
            self.label = label
        }

        public mutating func nextByte() -> UInt8 {
            if offset == block.count {
                let n = counter
                let message = label + [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
                block = Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
                counter &+= 1
                offset = 0
            }
            defer { offset += 1 }
            return block[offset]
        }

        /// Eight bytes, big-endian.
        public mutating func nextUInt64() -> UInt64 {
            (0..<8).reduce(UInt64(0)) { value, _ in (value << 8) | UInt64(nextByte()) }
        }
    }
}

public enum AIIDeviceKeyError: Error, Equatable, CustomStringConvertible {
    case notAKey(String)
    case unreadable(String)

    public var description: String {
        switch self {
        case .notAKey(let path): return "\(path) is not a device key (expected \(AIIDeviceKey.byteCount * 2) hex digits)"
        case .unreadable(let path): return "could not read the key at \(path)"
        }
    }
}

// MARK: - The file

extension AIIDeviceKey {

    /// The key at `url`, or nil when there is no file. A file that is not a key
    /// throws: replacing it silently would orphan whatever was written with the
    /// real one.
    public static func load(from url: URL) throws -> AIIDeviceKey? {
        guard PrivateFile.exists(url) else { return nil }
        guard let data = FileManager.default.contents(atPath: PrivateFile.path(url)) else {
            throw AIIDeviceKeyError.unreadable(PrivateFile.path(url))
        }
        guard let key = AIIDeviceKey(hex: String(decoding: data, as: UTF8.self)) else {
            throw AIIDeviceKeyError.notAKey(PrivateFile.path(url))
        }
        return key
    }

    /// The key at `url`, made when absent. Never overwrites: two processes racing
    /// to create it end up with the same one.
    public static func loadOrCreate(at url: URL) throws -> (key: AIIDeviceKey, created: Bool) {
        if let existing = try load(from: url) { return (existing, false) }
        try PrivateFile.ensureDirectory(url.deletingLastPathComponent())
        let fresh = AIIDeviceKey.random()
        let published = try PrivateFile.publishIfAbsent(Data((fresh.hex + "\n").utf8), to: url, mode: 0o600)
        if published { return (fresh, true) }
        guard let winner = try load(from: url) else { throw AIIDeviceKeyError.unreadable(PrivateFile.path(url)) }
        return (winner, false)
    }

    /// The device key of `home`, or nil when none exists yet.
    public static func load(home: AIIHome) throws -> AIIDeviceKey? {
        try load(from: home.deviceKeyFile)
    }

    /// The device key of `home`, made when absent.
    public static func loadOrCreate(home: AIIHome) throws -> (key: AIIDeviceKey, created: Bool) {
        try loadOrCreate(at: home.deviceKeyFile)
    }

}

// MARK: - Regenerating, and switching back

extension AIIDeviceKey {
    /// A key kept beside the current one: an earlier key a corpus may still be
    /// written with.
    public struct KeptKey: Sendable, Equatable, Identifiable {
        public let key: AIIDeviceKey
        public let file: URL
        public var fingerprint: String { key.fingerprint }
        public var id: String { PrivateFile.path(file) }

        public init(key: AIIDeviceKey, file: URL) {
            self.key = key
            self.file = file
        }
    }

    /// The name a key is kept under: `device-<fingerprint>.key`.
    static func keptName(_ key: AIIDeviceKey) -> String { "device-\(key.fingerprint).key" }

    /// The keys kept beside `url`, most recently written first. Files that are
    /// not keys are left out.
    public static func kept(beside url: URL) -> [KeptKey] {
        let directory = url.deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let kept = files.compactMap { file -> (KeptKey, Date)? in
            let name = file.lastPathComponent
            guard name.hasPrefix("device-"), name.hasSuffix(".key"), let key = try? load(from: file) else { return nil }
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return (KeptKey(key: key, file: file), date)
        }
        return kept.sorted { $0.1 > $1.1 }.map(\.0)
    }

    public static func kept(home: AIIHome) -> [KeptKey] { kept(beside: home.deviceKeyFile) }

    /// A new key at `url`. The current one, when there is one, is kept beside it first.
    /// - Returns: the new key, and where the previous one now is.
    @discardableResult
    public static func regenerate(at url: URL) throws -> (key: AIIDeviceKey, kept: URL?) {
        let keptFile = try keepCurrent(at: url)
        let (key, _) = try loadOrCreate(at: url)
        return (key, keptFile)
    }

    /// Makes a kept key the current one again; the current one is kept in its place.
    @discardableResult
    public static func use(_ keptFile: URL, at url: URL) throws -> AIIDeviceKey {
        guard let chosen = try load(from: keptFile) else {
            throw AIIDeviceKeyError.unreadable(PrivateFile.path(keptFile))
        }
        if let current = try load(from: url), current == chosen { return chosen }
        _ = try keepCurrent(at: url)
        try FileManager.default.moveItem(at: keptFile, to: url)
        return chosen
    }

    /// Moves the key at `url` aside as `device-<fingerprint>.key`; nil when there
    /// is none. A file that is not a key is an error rather than something to move.
    static func keepCurrent(at url: URL) throws -> URL? {
        guard let current = try load(from: url) else { return nil }
        let keptFile = url.deletingLastPathComponent().appendingPathComponent(keptName(current))
        if let already = try? load(from: keptFile), already == current {
            // Kept before, under the same name: the copy here is the same key.
            try FileManager.default.removeItem(at: url)
        } else {
            try FileManager.default.moveItem(at: url, to: keptFile)
        }
        return keptFile
    }
}
