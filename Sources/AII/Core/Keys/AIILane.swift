//
//  AIILane.swift
//  AII
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The lanes of the index, and their manifest. A lane is one app's share of the one
//        Thread: a uuid derived once from the device key and written, with the app's
//        display name, bundle id, owner and registration, to ~/.rao/aii/lanes.json
//        (format aii-lanes/1, defined in Protos/lanes.proto as aii.v1.LaneManifest). After
//        that the file is the registration, and rotating the device key moves no data.
//  IN:   Thread (which lane a caller's secret puts it in), Sewn (the caller's lane and its
//        no-account owner), registration (AIIHome.register), the aii command (aii lanes).
//  OUT:  `id(for:)`, `app(for:)`, `lane(for:)`, `owner(for:)`; `LaneID.unscoped` for a
//        server running open or for one app alone, where there are no lanes to tell apart.
//  PIN:  A lane is never trusted from a client. Both servers derive it from the secret
//        that matched; a client that names a lane is ignored or refused. Derivation:
//        UUID(bytes: HMAC-SHA256(deviceKey, "rao-lane-v1:" + app)[0..<16]), lowercase.
//        The first registration of a name wins its display name; an explicit owner
//        (aii-local or local-<app>) updates its entry. Today the servers admit any app
//        whose secret is in secrets/; the manifest is laid out so a later change can make
//        them admit only the lanes it lists. A lanes.json in another format reads as
//        absent and is rebuilt from secrets/, with the same ids from the same device key.
//

import Crypto
import Foundation

/// A lane's id: a lowercase uuid, or `unscoped` ("") where lanes don't apply.
public struct LaneID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue.lowercased() }
    public init(_ rawValue: String) { self.init(rawValue: rawValue) }

    /// The lane of a server running open or for one app alone: no lanes.
    public static let unscoped = LaneID(rawValue: "")

    public var isUnscoped: Bool { rawValue.isEmpty }
    public var description: String { rawValue.isEmpty ? "unscoped" : rawValue }
}

/// A lane keys Thread's registry maps, so a `[LaneID: …]` encodes as a keyed
/// container (plist dictionary), not as a flat key/value array.
extension LaneID: CodingKeyRepresentable {}

public struct AIILanes: Sendable, Equatable {
    public static let format = "aii-lanes/1"
    public static let derivationDomain = "rao-lane-v1:"

    /// One app's lane, as the manifest lists it.
    public struct Lane: Codable, Sendable, Equatable {
        public var id: LaneID
        /// The fingerprint of the device key the id was derived from.
        public var derivedFrom: String
        public var registeredAt: Date
        /// How people read the app's name.
        public var displayName: String
        public var bundleIdentifier: String?
        /// The app itself, or the stack (`aii lanes add`, or provisioning by another identity).
        public var registeredBy: StackIdentity
        /// Whom the app's records are filed under, and whom Sewn answers as, with no account.
        public var owner: AIIOwner

        public init(id: LaneID, derivedFrom: String, registeredAt: Date, displayName: String,
                    bundleIdentifier: String? = nil, registeredBy: StackIdentity, owner: AIIOwner) {
            self.id = id
            self.derivedFrom = derivedFrom
            self.registeredAt = registeredAt
            self.displayName = displayName
            self.bundleIdentifier = bundleIdentifier
            self.registeredBy = registeredBy
            self.owner = owner
        }
    }

    /// By app name.
    public var lanes: [AIIApp: Lane]

    public init(lanes: [AIIApp: Lane]) {
        self.lanes = lanes
    }

    public func id(for app: AIIApp) -> LaneID? { lanes[app]?.id }

    public func lane(for app: AIIApp) -> Lane? { lanes[app] }

    public func app(for id: LaneID) -> AIIApp? {
        lanes.first { $0.value.id == id }?.key
    }

    public func contains(_ id: LaneID) -> Bool { app(for: id) != nil }

    /// The app's no-account owner: its entry's, else the one a new lane would get.
    public func owner(for app: AIIApp) -> AIIOwner { lanes[app]?.owner ?? Self.defaultOwner(for: app) }

    /// The registered apps, by name.
    public var apps: [AIIApp] { lanes.keys.sorted() }

    public var ids: [LaneID] { apps.compactMap { lanes[$0]?.id } }

    /// The owner a new lane starts with: `aii-local` for the Rao apps (Ambient, Craft,
    /// Veil), which file there without an account; an app's own otherwise.
    public static func defaultOwner(for app: AIIApp) -> AIIOwner {
        AIIApp.allCases.contains(app) ? .local : .app(app)
    }

    public static func derive(app: AIIApp, from key: AIIDeviceKey) -> LaneID {
        let mac = key.mac(label: derivationDomain, message: Data(app.rawValue.utf8))
        let bytes = Array(mac.prefix(16))
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return LaneID(rawValue: uuid.uuidString.lowercased())
    }

    // MARK: - The file

    /// The manifest in `home`, or nil when none was written yet (or one in another format).
    public static func load(home: AIIHome) throws -> AIILanes? {
        guard let file = try loadFile(home: home) else { return nil }
        return AIILanes(byName: file.lanes)
    }

    /// The manifest in `home`, with a lane for each of `apps` (default: every app registered
    /// there) added in place when missing. Ids are derived from the device key (made when
    /// absent) under the lanes lock; an entry once written keeps its id.
    @discardableResult
    public static func ensure(home: AIIHome, apps: [AIIApp]? = nil, by registrant: StackIdentity = .stack,
                              now: Date = Date()) throws -> AIILanes {
        let wanted = apps ?? home.registeredApps()
        let existing = try load(home: home)
        if wanted.allSatisfy({ existing?.lanes[$0] != nil }) {
            return existing ?? AIILanes(lanes: [:])
        }
        return try update(home: home) { byName, key in
            for app in wanted where byName[app.rawValue] == nil {
                byName[app.rawValue] = newLane(app, key: key, displayName: nil, bundleIdentifier: nil,
                                               owner: nil, by: registrant, now: now)
            }
        }
    }

    /// `app`'s lane, registered first when missing.
    @discardableResult
    public static func ensure(home: AIIHome, app: AIIApp, now: Date = Date()) throws -> LaneID {
        guard let id = try ensure(home: home, apps: [app], now: now).id(for: app) else {
            throw AIIHomeError.missing(PrivateFile.path(home.lanesFile))
        }
        return id
    }

    /// Registers `app`'s lane: added when missing, with `displayName` and `bundleIdentifier`;
    /// an existing entry keeps them (the first registration wins). An explicit `owner`
    /// replaces the entry's. Returns the entry as written.
    @discardableResult
    public static func register(home: AIIHome, app: AIIApp, displayName: String?, bundleIdentifier: String?,
                                owner: AIIOwner?, by registrant: StackIdentity, now: Date = Date()) throws -> Lane {
        if let owner, !owner.isLaneOwner(for: app) {
            throw AIIHomeError.invalidOwner(owner.rawValue, app: app.rawValue)
        }
        let lanes = try update(home: home) { byName, key in
            if var lane = byName[app.rawValue] {
                if let owner, lane.owner != owner { lane.owner = owner; byName[app.rawValue] = lane }
            } else {
                byName[app.rawValue] = newLane(app, key: key, displayName: displayName, bundleIdentifier: bundleIdentifier,
                                               owner: owner, by: registrant, now: now)
            }
        }
        guard let lane = lanes.lanes[app] else { throw AIIHomeError.missing(PrivateFile.path(home.lanesFile)) }
        return lane
    }

    /// Sets the no-account owner of `app`'s lane, which must already be registered.
    public static func setOwner(_ owner: AIIOwner, for app: AIIApp, home: AIIHome) throws {
        guard owner.isLaneOwner(for: app) else { throw AIIHomeError.invalidOwner(owner.rawValue, app: app.rawValue) }
        guard try load(home: home)?.lanes[app] != nil else { throw AIIHomeError.missing("\(app.rawValue)'s lane") }
        try update(home: home) { byName, _ in byName[app.rawValue]?.owner = owner }
    }

    /// Takes `app` out of the manifest, under the lanes lock.
    public static func remove(home: AIIHome, app: AIIApp) throws {
        guard PrivateFile.exists(home.lanesFile) else { return }
        try PrivateFile.withExclusiveLock(home.lanesLockFile) {
            guard var file = try loadFile(home: home), file.lanes.removeValue(forKey: app.rawValue) != nil else { return }
            try write(file, home: home)
        }
    }

    // MARK: - Internals

    /// The manifest as it is written: `{"format": "aii-lanes/1", "lanes": {name: lane}}`.
    struct File: Codable {
        var format: String
        var lanes: [String: Lane]
    }

    private init(byName: [String: Lane]) {
        var lanes: [AIIApp: Lane] = [:]
        for (name, lane) in byName {
            guard let app = AIIApp(rawValue: name) else { continue }
            lanes[app] = lane
        }
        self.init(lanes: lanes)
    }

    /// A new entry, its time to the second, as the file keeps it.
    private static func newLane(_ app: AIIApp, key: AIIDeviceKey, displayName: String?, bundleIdentifier: String?,
                                owner: AIIOwner?, by registrant: StackIdentity, now: Date) -> Lane {
        Lane(id: derive(app: app, from: key), derivedFrom: key.fingerprint, registeredAt: AIIRecord.wholeSecond(now),
             displayName: displayName ?? app.displayName, bundleIdentifier: bundleIdentifier,
             registeredBy: registrant, owner: owner ?? defaultOwner(for: app))
    }

    /// Reads, changes and writes the manifest under the lanes lock; writes only on a change.
    @discardableResult
    private static func update(home: AIIHome, _ change: (inout [String: Lane], AIIDeviceKey) throws -> Void) throws -> AIILanes {
        let (key, _) = try AIIDeviceKey.loadOrCreate(home: home)
        try PrivateFile.ensureDirectory(home.aiiDirectory)
        return try PrivateFile.withExclusiveLock(home.lanesLockFile) {
            let before = try loadFile(home: home)
            var byName = before?.lanes ?? [:]
            try change(&byName, key)
            if before?.lanes != byName {
                try write(File(format: format, lanes: byName), home: home)
            }
            return AIILanes(byName: byName)
        }
    }

    private static func write(_ file: File, home: AIIHome) throws {
        try PrivateFile.writeAtomically(try AIIHome.encoder.encode(file), to: home.lanesFile, mode: 0o600)
    }

    /// The file, or nil when absent or in another format (it is then rebuilt, start fresh).
    static func loadFile(home: AIIHome) throws -> File? {
        guard let data = FileManager.default.contents(atPath: PrivateFile.path(home.lanesFile)) else { return nil }
        guard let file = try? AIIHome.decoder.decode(File.self, from: data), file.format == format else { return nil }
        return file
    }
}
