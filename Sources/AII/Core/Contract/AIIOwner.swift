//
//  AIIOwner.swift
//  AII
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Whom a document is filed under, and whom Sewn answers as: the `owner_id` of every
//        Thread request (index, search, remove, documents, library, export, graph).
//  IN:   AIIInstance, AIIDocument.indexRequests, an app's own Thread client, the lanes
//        manifest (a lane's owner when nobody is signed in).
//  OUT:  `local` (`aii-local`), `app(_:)` (`local-<app>`), `account(_:)` (a person's id).
//  PIN:  Owners partition a lane by person: a search, a remove or an export sees only the
//        owner it names. Without an account an app files under `local-<app>`, its own, or
//        under `aii-local`, the one owner every app that opts in shares, so all of this
//        Mac's local records sit under one owner, each still in its own app's lane. A
//        lane's no-account owner is its entry in aii/lanes.json, which Sewn reads too, so
//        recall and ask see the same documents. Groups are bound to the first owner and
//        lane that file into them; a shared owner is safe because every app's group ids
//        start with its name (`<app>-<group>`).
//

import Foundation

public struct AIIOwner: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    /// `aii-local`: the one no-account owner every app that opts in files under.
    public static let local = AIIOwner(rawValue: "aii-local")

    /// `local-<app>`: an app's own no-account owner, which a new lane starts with (the Rao
    /// apps' lanes start under `aii-local`: AIILanes.defaultOwner).
    public static func app(_ app: AIIApp) -> AIIOwner { AIIOwner(rawValue: "local-\(app.rawValue)") }

    /// A signed-in person, by their account id, lowercased as Sewn does.
    public static func account(_ id: String) -> AIIOwner { AIIOwner(rawValue: id.lowercased()) }

    /// No account: `aii-local` or `local-<app>`. A record under one is unclaimed.
    public var isLocal: Bool { self == .local || rawValue.hasPrefix("local-") }

    /// Whether `app`'s lane may name this owner in the lanes manifest: `aii-local` or its own.
    public func isLaneOwner(for app: AIIApp) -> Bool { self == .local || self == .app(app) }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
