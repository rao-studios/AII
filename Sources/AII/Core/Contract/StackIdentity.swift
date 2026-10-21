//
//  StackIdentity.swift
//  AII
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Who can hold a stack secret: an app, or the stack itself.
//  IN:   The keyring (which secret matched), admission (who is calling), /health
//        (whose secret to prove), Seam's resolver (what Sewn records a node as), and
//        the records that say who installed, launched or holds the stack.
//  OUT:  `aii` on the wire for the stack; an app's own name for an app.
//  PIN:  The stack identity (`secrets/aii`) is what the one Thread registers with Sewn
//        as, what a stack-wide operation (clearing every lane, reading every lane's
//        stats) must present, and what the `aii` command acts as. It is never an
//        `AIIApp`: lanes are for apps, and `AIIApp(rawValue: "aii")` stays nil. The set
//        of identities is open like the apps; a home's identities are the names in its
//        secrets/. Encoded as its raw string.
//

import Foundation

public enum StackIdentity: Hashable, Comparable, Sendable, CustomStringConvertible {
    case app(AIIApp)
    case stack

    public static let stackRawValue = "aii"

    public init?(rawValue: String) {
        if rawValue == Self.stackRawValue {
            self = .stack
        } else if let app = AIIApp(rawValue: rawValue) {
            self = .app(app)
        } else {
            return nil
        }
    }

    /// An identity named by a header or an environment value: trimmed, any case.
    public init?(header: String?) {
        guard let header else { return nil }
        self.init(rawValue: header.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    public var rawValue: String {
        switch self {
        case .app(let app): return app.rawValue
        case .stack: return Self.stackRawValue
        }
    }

    /// The file under AII_HOME/secrets.
    public var fileName: String { rawValue }

    public var app: AIIApp? {
        if case .app(let app) = self { return app }
        return nil
    }

    public var isStack: Bool { self == .stack }

    public var displayName: String {
        switch self {
        case .app(let app): return app.displayName
        case .stack: return "Ambient Intelligence Index"
        }
    }

    /// An app's registered display name on `home`; the stack's own name otherwise.
    public func displayName(in home: AIIHome) -> String {
        app?.displayName(in: home) ?? displayName
    }

    public var description: String { rawValue }

    /// By name, so the stack (`aii`) sorts first.
    public static func < (lhs: StackIdentity, rhs: StackIdentity) -> Bool { lhs.rawValue < rhs.rawValue }
}

extension StackIdentity: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let identity = StackIdentity(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "\(raw) names no stack identity"))
        }
        self = identity
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
