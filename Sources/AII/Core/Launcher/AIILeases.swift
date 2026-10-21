//
//  AIILeases.swift
//  AII
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Who still needs the stack. Each app holds a lease while it runs; the aii
//        command pins one, as the stack identity, until it lets go.
//  IN:   Launchers (acquire before starting, release at quit), quit paths
//        deciding whether to stop the two servers.
//  OUT:  `live()`: stop the servers only when it is empty.
//  PIN:  Synchronous on purpose — an app's terminate handler can't await. A
//        lease is live while its process is (pid and start time), so a crashed
//        app never keeps the stack up forever; dead leases are swept on read. A
//        lease keeps the servers running; it never keeps an old build of them
//        running (ManagedServer.isStale). A lease covers both servers: the one
//        Thread is every app's, like Sewn.
//

#if os(macOS)
import Foundation

public struct AIILeases: Sendable {
    public let home: AIIHome

    public init(home: AIIHome) {
        self.home = home
    }

    /// Records that `identity` (this process) needs the stack. A pinned lease outlives
    /// the process that wrote it.
    public func acquire(for identity: StackIdentity, pinned: Bool = false, process: ProcessStamp = ProcessProbe.current,
                        now: Date = Date()) throws {
        try PrivateFile.ensureDirectory(home.aiiLeasesDirectory)
        let lease = AIILease(identity: identity, process: process, pinned: pinned, acquiredAt: now)
        let file = pinned ? home.aiiPinnedLease(for: identity) : home.aiiLease(for: identity)
        try PrivateFile.writeAtomically(try AIIHome.encoder.encode(lease), to: file, mode: 0o600)
    }

    public func acquire(for app: AIIApp, pinned: Bool = false, process: ProcessStamp = ProcessProbe.current,
                        now: Date = Date()) throws {
        try acquire(for: .app(app), pinned: pinned, process: process, now: now)
    }

    /// Lets go of `identity`'s lease (its pinned one, when `pinned`). An unpinned
    /// lease is only removed by the process that holds it, so a second copy
    /// of an app (Craft's CLI beside Craft.app) can't drop the first's.
    public func release(for identity: StackIdentity, pinned: Bool = false, heldBy holder: ProcessStamp = ProcessProbe.current) {
        let file = pinned ? home.aiiPinnedLease(for: identity) : home.aiiLease(for: identity)
        if !pinned,
           let data = FileManager.default.contents(atPath: PrivateFile.path(file)),
           let lease = try? AIIHome.decoder.decode(AIILease.self, from: data),
           lease.process.pid != holder.pid,
           ProcessProbe.isRunning(lease.process) {
            return
        }
        try? FileManager.default.removeItem(at: file)
    }

    public func release(for app: AIIApp, pinned: Bool = false, heldBy holder: ProcessStamp = ProcessProbe.current) {
        release(for: .app(app), pinned: pinned, heldBy: holder)
    }

    /// Every lease that is still live, dead ones removed.
    public func live() -> [AIILease] {
        let directory = home.aiiLeasesDirectory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: PrivateFile.path(directory)) else { return [] }
        var leases: [AIILease] = []
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let file = directory.appendingPathComponent(name)
            guard let data = FileManager.default.contents(atPath: PrivateFile.path(file)),
                  let lease = try? AIIHome.decoder.decode(AIILease.self, from: data) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            if lease.pinned || ProcessProbe.isRunning(lease.process) {
                leases.append(lease)
            } else {
                try? FileManager.default.removeItem(at: file)
            }
        }
        return leases.sorted { $0.acquiredAt < $1.acquiredAt }
    }

    /// The identities holding a live lease.
    public func liveHolders() -> [StackIdentity] {
        var seen: [StackIdentity] = []
        for lease in live() where !seen.contains(lease.identity) { seen.append(lease.identity) }
        return seen
    }

    /// Whether anyone other than `identity`'s own (unpinned) lease needs the stack:
    /// another identity, or a pinned lease of any.
    public func othersAlive(excluding identity: StackIdentity) -> Bool {
        live().contains { $0.identity != identity || $0.pinned }
    }

    /// Who, other than `identity`, is holding the stack — for a "shared with …" line.
    public func others(excluding identity: StackIdentity) -> [StackIdentity] {
        var seen: [StackIdentity] = []
        for lease in live() where (lease.identity != identity || lease.pinned) && !seen.contains(lease.identity) {
            seen.append(lease.identity)
        }
        return seen
    }
}
#endif
