//
//  AIIHome+Registration.swift
//  AII
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Making an app a lane of the index on this Mac: its secret, and its entry in the
//        lanes manifest (aii/lanes.json: the lane id, display name, bundle id, owner, and
//        who registered it and when); and undoing that.
//  IN:   An app's supervisor or AIIInstance on prepare()/join(); `aii lanes add`, `owner` and
//        `remove`; provisioning, for the apps every home starts with.
//  OUT:  Two files per app, `lane(_:)`, and `registeredApps()`: every app this home knows.
//  PIN:  The first registration of a name wins: the secret is published with link(), never
//        overwritten, the lane id is derived once from the device key, and the display name
//        stays the first registrant's. A second app registering the same name inherits the
//        first's lane. An explicit owner updates the entry. The running servers admit a new
//        app on their keyring's next miss, and read its lane and owner on their lane
//        registry's next reload, so registering restarts nothing. Unregistering removes the
//        secret and the entry only: the app's documents stay in Thread and its folder under
//        apps/ stays, so registering the name again on the same device key finds them.
//

import Foundation

extension AIIHome {

    /// Registers `app` here: its secret and its lane, each only when missing; an explicit
    /// `owner` (aii-local or the app's own) updates the lane's. Returns the lane as written,
    /// which is the first registrant's when there was one.
    @discardableResult
    public func register(_ app: AIIApp, displayName: String? = nil, bundleIdentifier: String? = nil,
                         owner: AIIOwner? = nil, by registrant: StackIdentity? = nil,
                         now: Date = Date()) throws -> AIILanes.Lane {
        try PrivateFile.ensureDirectory(appsDirectory)
        try PrivateFile.ensureDirectory(appDirectory(app))
        _ = try ensureSecret(for: app)
        return try AIILanes.register(home: self, app: app, displayName: displayName, bundleIdentifier: bundleIdentifier,
                                     owner: owner, by: registrant ?? .app(app), now: now)
    }

    /// The app's lane in the manifest, when it has one.
    public func lane(_ app: AIIApp) -> AIILanes.Lane? {
        (try? AIILanes.load(home: self))??.lane(for: app)
    }

    /// Every app this home knows, by name: each app name in secrets/ (never `aii`) and each
    /// lane in the manifest.
    public func registeredApps() -> [AIIApp] {
        var apps = Set<AIIApp>()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: PrivateFile.path(secretsDirectory))) ?? []
        for name in names where !name.hasPrefix(".") {
            if let app = AIIApp(rawValue: name) { apps.insert(app) }
        }
        if let lanes = try? AIILanes.load(home: self) { apps.formUnion(lanes.lanes.keys) }
        return apps.sorted()
    }

    /// Sets the no-account owner of `app`'s lane: `.local` (aii-local) or `.app(app)`.
    public func setOwner(_ owner: AIIOwner, for app: AIIApp) throws {
        try AIILanes.setOwner(owner, for: app, home: self)
    }

    /// Removes `app`'s secret and lane entry. Its documents in Thread and its folder under
    /// apps/ stay.
    public func unregister(_ app: AIIApp) throws {
        try AIILanes.remove(home: self, app: app)
        let secret = secretFile(for: app)
        if PrivateFile.exists(secret) { try FileManager.default.removeItem(at: secret) }
    }
}
