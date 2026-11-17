//
//  AIILabel.swift
//  AII
//
//  Created by Ritesh Pakala on 11/16/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: An AII's own name, as its owner gave it: one short line kept in the
//        home (`aii/label.json`) and said on both servers' /health, so whoever
//        finds the AII on a port can call it by name instead of by its port.
//  IN:   `aii label` (the person), any app that manages AII homes (writing
//        through `write`), and the servers (reading through `current`).
//  OUT:  /health's `label`, when the home has one.
//  PIN:  A NAME, NEVER A KEY. It is public by design (keyless /health), so it
//        proves nothing and unlocks nothing: a reader may show it, never trust it.
//  PIN:  A running server reads it again when the file changes, so a label set
//        while the AII runs is its next /health's, with no restart. Only a server
//        whose launcher named its home (AII_HOME) has one: an open server has no
//        home, so no label.
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public struct AIILabel: Codable, Sendable, Equatable {
    /// The longest a label may be, in characters.
    public static let maximumLength = 64

    public var label: String
    public var setAt: Date

    public init(label: String, setAt: Date) {
        self.label = label
        self.setAt = setAt
    }

    /// `text` as a label: trimmed, one line of 1 to 64 characters with no control
    /// characters; nil when it can't be one.
    public static func normalized(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumLength else { return nil }
        guard !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return trimmed
    }

    // MARK: - The file

    /// The home's label, when it has one that reads.
    public static func read(home: AIIHome) -> String? {
        guard let data = FileManager.default.contents(atPath: PrivateFile.path(home.labelFile)),
              let file = try? AIIHome.decoder.decode(AIILabel.self, from: data) else { return nil }
        return normalized(file.label)
    }

    /// Names the home `text`. Returns the label as kept; throws when `text` can't be one.
    @discardableResult
    public static func write(_ text: String, home: AIIHome, now: Date = Date()) throws -> String {
        guard let label = normalized(text) else { throw AIILabelError.invalid(text) }
        try PrivateFile.ensureDirectory(home.aiiDirectory)
        try PrivateFile.writeAtomically(try AIIHome.encoder.encode(AIILabel(label: label, setAt: now)), to: home.labelFile)
        return label
    }

    /// Takes the home's label away; nothing to take is not an error.
    public static func clear(home: AIIHome) {
        unlink(PrivateFile.path(home.labelFile))
    }

    // MARK: - For servers

    /// The home's label now, read again only when the file changed since the last
    /// read: what /health says, at every ask.
    public static func current(home: AIIHome) -> String? {
        cache.label(home: home)
    }

    private static let cache = Cache()

    /// The last label read per home, and the file's stamp when it was read.
    private final class Cache: @unchecked Sendable {
        private struct Entry {
            var stamp: Stamp?
            var label: String?
        }

        private struct Stamp: Equatable {
            var modified: timespec
            var size: off_t

            static func == (lhs: Stamp, rhs: Stamp) -> Bool {
                lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec && lhs.size == rhs.size
            }
        }

        private let lock = NSLock()
        private var entries: [String: Entry] = [:]

        func label(home: AIIHome) -> String? {
            let path = PrivateFile.path(home.labelFile)
            let now = Self.stamp(path)
            return lock.withLock {
                if let entry = entries[path], entry.stamp == now { return entry.label }
                let label = now == nil ? nil : AIILabel.read(home: home)
                entries[path] = Entry(stamp: now, label: label)
                return label
            }
        }

        private static func stamp(_ path: String) -> Stamp? {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            #if canImport(Darwin)
            return Stamp(modified: info.st_mtimespec, size: info.st_size)
            #else
            return Stamp(modified: info.st_mtim, size: info.st_size)
            #endif
        }
    }
}

public enum AIILabelError: Error, Equatable, CustomStringConvertible {
    case invalid(String)

    public var description: String {
        switch self {
        case .invalid(let text):
            return "\"\(text)\" is not a label: one line of 1 to \(AIILabel.maximumLength) characters"
        }
    }
}
