//
//  AIIApp.swift
//  AII
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: An app's name in the Ambient Intelligence Index: what its secret, its lane, its
//        lease and its folder are filed under. Any app may have one; Ambient, Craft and
//        Veil are the three every home starts with. Also the ports the shared Sewn and
//        the one Thread listen on.
//  IN:   An app's descriptor or supervisor (`"notes"`), header and environment values,
//        the names under secrets/ and the lanes in the manifest (aii/lanes.json).
//  OUT:  A validated name, and `allCases`: the apps every home is provisioned with.
//  PIN:  The set is open. A name is `^[a-z][a-z0-9]{1,31}$`, and `aii`, the stack's own
//        identity, is never one. No `-`, so a wire group `<app>-<group>` always splits at
//        its first `-` (AIIRecord.parseGroupID). The first app to register a name on a Mac owns its
//        secret, lane and display name there (AIIHome.register); a later app with the
//        same name inherits that lane. A lane separates apps' mistakes, not their malice:
//        any process running as the person can read any secret. `allCases` is not every
//        app. It is the three a home starts with, and Braid reads it under that name;
//        `AIIHome.registeredApps()` is every app a home knows. The ports stay clear of the
//        8080/8081/9090/9091/9092 defaults Mary, Bonnie and Fleet run open stacks on.
//

import Foundation

public struct AIIApp: RawRepresentable, Codable, Hashable, Comparable, Sendable,
                      CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String

    /// Nil for anything that isn't an app name, including the stack's own `aii`.
    public init?(rawValue: String) {
        guard Self.isValidName(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    /// A literal is the developer's own constant, so an invalid one is a programming error.
    public init(stringLiteral value: String) {
        guard let app = AIIApp(rawValue: value) else {
            preconditionFailure("\"\(value)\" is not an app name: \(Self.namePattern), and never \"\(StackIdentity.stackRawValue)\"")
        }
        self = app
    }

    /// An app named by a header or an environment value: trimmed, any case. Nil for
    /// anything that isn't an app name, including the stack's own `aii`.
    public init?(header: String?) {
        guard let header else { return nil }
        self.init(rawValue: header.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// The name as typed by a person (`aii lanes add`): the reason when it can't be one.
    public static func named(_ name: String) throws -> AIIApp {
        if name == StackIdentity.stackRawValue { throw AIIHomeError.reservedName(name) }
        guard let app = AIIApp(rawValue: name) else { throw AIIHomeError.invalidAppName(name) }
        return app
    }

    public static let ambient: AIIApp = "ambient"
    public static let craft: AIIApp = "craft"
    public static let veil: AIIApp = "veil"

    /// The apps every home is provisioned with, so their lanes exist before they launch.
    /// Every app a home knows is `AIIHome.registeredApps()`.
    public static let allCases: [AIIApp] = [.ambient, .craft, .veil]

    public static let namePattern = "^[a-z][a-z0-9]{1,31}$"

    public static func isValidName(_ name: String) -> Bool {
        guard name != StackIdentity.stackRawValue else { return false }
        let bytes = Array(name.utf8)
        guard (2...32).contains(bytes.count), let first = bytes.first, isLower(first) else { return false }
        return bytes.dropFirst().allSatisfy { isLower($0) || isDigit($0) }
    }

    private static func isLower(_ byte: UInt8) -> Bool { (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) }
    private static func isDigit(_ byte: UInt8) -> Bool { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) }

    /// The name with its first letter capitalized: "notes" → "Notes".
    public var displayName: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// The display name the app registered on `home` (its lane in the manifest), else `displayName`.
    public func displayName(in home: AIIHome) -> String {
        home.lane(self)?.displayName ?? displayName
    }

    public var description: String { rawValue }

    public static func < (lhs: AIIApp, rhs: AIIApp) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct AIIPorts: Codable, Hashable, Sendable, CustomStringConvertible {
    public var http: Int
    public var grpc: Int

    public init(http: Int, grpc: Int) {
        self.http = http
        self.grpc = grpc
    }

    public var description: String { "http \(http), grpc \(grpc)" }
}

public enum AIIPortPlan {
    /// The one Sewn every app shares.
    public static let sewn = AIIPorts(http: 47080, grpc: 47091)

    /// The one Thread every app shares.
    public static let thread = AIIPorts(http: 47081, grpc: 47090)

    /// The defaults other stacks on this machine use (Mary, Bonnie, Fleet and
    /// the servers' own flags). Nothing in the plan may land on one.
    public static let reservedElsewhere: Set<Int> = [8080, 8081, 9090, 9091, 9092]
}
