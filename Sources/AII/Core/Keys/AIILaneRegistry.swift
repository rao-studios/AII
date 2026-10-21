//
//  AIILaneRegistry.swift
//  AII
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The servers' live view of the lanes manifest (aii/lanes.json): which lane an app
//        files under, which app a lane belongs to, and whom Sewn answers as for an app with
//        no account — for apps registered, or owners changed, after the server started too.
//  IN:   Sewn (stamping the caller's lane on what it forwards; a no-account caller's
//        owner) and Thread (the lane a caller's secret puts it in, and whether a stamped
//        lane is registered).
//  OUT:  `id(for:)`, `app(for:)`, `contains`, `owner(for:)`, `displayName(for:)`.
//  PIN:  Cached, and read again at most once per `minimumReloadInterval`: on a miss, as
//        StackKeyring reads secrets/, and whenever the manifest's modification time has
//        changed, so `aii lanes owner` reaches a running server. A miss on `id(for:)` comes
//        only from an app the keyring already admitted, so it registers that app's lane in
//        place (AIILanes.ensure) rather than failing: an app that wrote its secret and
//        stopped before its lane still gets one, the same one any later call derives.
//

import Foundation

public enum AIILaneRegistryError: Error, Equatable, CustomStringConvertible {
    case unregistered(AIIApp)

    public var description: String {
        switch self {
        case .unregistered(let app): return "no lane is registered for \(app.rawValue), and this server has no home to register one in"
        }
    }
}

public final class AIILaneRegistry: @unchecked Sendable {
    private let home: AIIHome?
    private let minimumReloadInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var lanes: AIILanes
    private var loadedAt: Date
    private var loadedModified: Date?

    /// The registry of `home`'s lanes.json.
    public init(home: AIIHome, minimumReloadInterval: TimeInterval = 2, now: @escaping @Sendable () -> Date = { Date() }) {
        self.home = home
        self.minimumReloadInterval = minimumReloadInterval
        self.now = now
        self.lanes = (try? AIILanes.load(home: home)) ?? AIILanes(lanes: [:])
        self.loadedAt = now()
        self.loadedModified = Self.modified(home)
    }

    /// A fixed registry, for tests: never reads a file and never registers.
    public init(fixed lanes: AIILanes) {
        self.home = nil
        self.minimumReloadInterval = .infinity
        self.now = { Date() }
        self.lanes = lanes
        self.loadedAt = Date()
    }

    /// What the registry holds now.
    public var snapshot: AIILanes { lock.withLock { lanes } }

    /// Whom Sewn answers as for `app` when it calls with no account: its lane's owner in the
    /// manifest (aii-local, or local-<app>), read again when the manifest has changed.
    public func owner(for app: AIIApp) -> AIIOwner {
        reloadIfChanged()
        return lock.withLock { lanes.owner(for: app) }
    }

    /// The lane `app` files under; registered now when lanes.json has none for it.
    public func id(for app: AIIApp) throws -> LaneID {
        if let id = lock.withLock({ lanes.id(for: app) }) { return id }
        guard let home else { throw AIILaneRegistryError.unregistered(app) }
        let ensured = try AIILanes.ensure(home: home, apps: [app])
        let stamp = now()
        let modified = Self.modified(home)
        lock.withLock {
            lanes = ensured
            loadedAt = stamp
            loadedModified = modified
        }
        guard let id = ensured.id(for: app) else { throw AIILaneRegistryError.unregistered(app) }
        return id
    }

    /// The app a lane belongs to, or nil when no registered app has it.
    public func app(for id: LaneID) -> AIIApp? {
        if let app = lock.withLock({ lanes.app(for: id) }) { return app }
        guard reloadIfAllowed() else { return nil }
        return lock.withLock { lanes.app(for: id) }
    }

    public func contains(_ id: LaneID) -> Bool { app(for: id) != nil }

    /// The app's registered display name, when the registry has a home.
    public func displayName(for app: AIIApp) -> String {
        home.map { app.displayName(in: $0) } ?? app.displayName
    }

    private func reloadIfAllowed() -> Bool {
        guard let home else { return false }
        let stamp = now()
        guard stamp.timeIntervalSince(lock.withLock({ loadedAt })) >= minimumReloadInterval else { return false }
        let modified = Self.modified(home)
        let fresh = (try? AIILanes.load(home: home)) ?? AIILanes(lanes: [:])
        lock.withLock {
            lanes = fresh
            loadedAt = stamp
            loadedModified = modified
        }
        return true
    }

    /// Reloads when the manifest's modification time differs from the one last read, at
    /// most once per `minimumReloadInterval`.
    private func reloadIfChanged() {
        guard let home, Self.modified(home) != lock.withLock({ loadedModified }) else { return }
        _ = reloadIfAllowed()
    }

    private static func modified(_ home: AIIHome) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: PrivateFile.path(home.lanesFile)))?[.modificationDate] as? Date
    }
}
