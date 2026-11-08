//
//  AIIBusy.swift
//  AII
//
//  Created by Ritesh Pakala on 11/07/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Who is generating on this Mac's GPU right now. An app marks itself busy while its own model
//        generates (Craft's turn); the stack's own background model work (Thread's readings) waits
//        while any mark is live, and goes on when the last one is gone.
//  IN:   Apps (`hold` when a turn starts and again to renew it, `release` when it ends), Thread's
//        extractor gate (`live`, before each reading).
//  OUT:  The marks of running processes that have not expired; dead or expired ones are swept.
//  PIN:  A FILE PER APP AND PROCESS under AII_HOME/aii/busy, so Craft's CLI and Craft.app never clear
//        each other's mark. A mark expires on its own (`expiresAt`) so a stuck app can't hold the
//        readings off for ever, and dies with its process (pid and start time) so a crash leaves
//        nothing behind. Synchronous, like leases: a terminate handler can't await.
//

#if os(macOS)
import Foundation

/// One app process generating on the GPU, until `expiresAt` unless it renews.
public struct AIIBusyMark: Codable, Sendable, Equatable {
    public var app: AIIApp
    public var process: ProcessStamp
    /// When this run of generating began (kept across renewals).
    public var since: Date
    public var expiresAt: Date

    public init(app: AIIApp, process: ProcessStamp, since: Date, expiresAt: Date) {
        self.app = app
        self.process = process
        self.since = since
        self.expiresAt = expiresAt
    }
}

public struct AIIBusy: Sendable {
    /// How long a mark holds without renewal. An app renews well inside it while it generates.
    public static let lifetime: TimeInterval = 600

    public let home: AIIHome

    public init(home: AIIHome) {
        self.home = home
    }

    /// Marks `app` (this process) as generating, or renews its mark; `since` is kept on renewal.
    public func hold(for app: AIIApp, lifetime: TimeInterval = AIIBusy.lifetime,
                     process: ProcessStamp = ProcessProbe.current, now: Date = Date()) throws {
        try PrivateFile.ensureDirectory(home.aiiBusyDirectory)
        let file = home.aiiBusyMark(for: app, pid: process.pid)
        let previous = read(file).flatMap { $0.process == process && $0.expiresAt > now ? $0 : nil }
        let mark = AIIBusyMark(app: app, process: process, since: previous?.since ?? now,
                               expiresAt: now.addingTimeInterval(lifetime))
        try PrivateFile.writeAtomically(try AIIHome.encoder.encode(mark), to: file, mode: 0o600)
    }

    /// Lets go of `app`'s mark for this process.
    public func release(for app: AIIApp, process: ProcessStamp = ProcessProbe.current) {
        try? FileManager.default.removeItem(at: home.aiiBusyMark(for: app, pid: process.pid))
    }

    /// Every live mark, oldest first; a mark whose process is gone, that expired, or that can't be read is removed.
    public func live(now: Date = Date()) -> [AIIBusyMark] {
        let directory = home.aiiBusyDirectory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: PrivateFile.path(directory)) else { return [] }
        var marks: [AIIBusyMark] = []
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let file = directory.appendingPathComponent(name)
            guard let mark = read(file), mark.expiresAt > now, ProcessProbe.isRunning(mark.process) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            marks.append(mark)
        }
        return marks.sorted { $0.since < $1.since }
    }

    /// The apps generating now, each once.
    public func apps(now: Date = Date()) -> [AIIApp] {
        var seen: [AIIApp] = []
        for mark in live(now: now) where !seen.contains(mark.app) { seen.append(mark.app) }
        return seen
    }

    private func read(_ file: URL) -> AIIBusyMark? {
        guard let data = FileManager.default.contents(atPath: PrivateFile.path(file)) else { return nil }
        return try? AIIHome.decoder.decode(AIIBusyMark.self, from: data)
    }
}
#endif
