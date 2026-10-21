//
//  LaneDoctor.swift
//  AIICLI
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: One lane, walked down the runtime stack layer by layer: its manifest entry, its
//        secret, its lane id, its admission by both servers, Thread's view of it, its
//        groups, its records, its owner, and recent log lines. Each layer passes or says
//        what to fix; the first that fails is where a developer looks.
//  IN:   An app and a home; for the live layers, the running servers (as that app).
//  OUT:  DoctorChecks (`aii lanes doctor`, the studio's `d`).
//  PIN:  Read-only. The live layers read as the app itself — its secret, its lane — through
//        AIIClient and AIILaneInspector. The file layers come first, and a failure there
//        ends the walk, since nothing above them can work. `checks(_:home:observed:)` is
//        pure over what `gather` saw, so each layer can be tested failing on its own.
//

import AII
import Foundation

enum LaneDoctor {

    /// What the doctor saw of the running stack.
    struct Observations {
        var sewn: StackVerdict
        var thread: StackVerdict
        var stats: Result<AIIStats, Error>?
        var inspection: Result<AIILaneInspection, Error>?
        /// Log lines since each server started that name the app or its lane and report a problem.
        var logs: [String]
    }

    /// Every layer for `app`, gathered live.
    static func run(_ app: AIIApp, home: AIIHome) async -> [DoctorCheck] {
        checks(app, home: home, observed: await gather(app, home: home))
    }

    static func gather(_ app: AIIApp, home: AIIHome) async -> Observations {
        let client = AIIClient(identity: .app(app), home: home)
        let (sewn, thread) = await client.health()
        let owner = ((try? AIILanes.load(home: home)) ?? nil)?.owner(for: app) ?? AIILanes.defaultOwner(for: app)
        var observed = Observations(sewn: sewn, thread: thread, stats: nil, inspection: nil, logs: [])
        if thread.isOurs {
            do { observed.stats = .success(try await client.stats()) } catch { observed.stats = .failure(error) }
            do {
                observed.inspection = .success(try await AIILaneInspector.inspect(app: app, owner: owner, home: home))
            } catch {
                observed.inspection = .failure(error)
            }
        }
        let laneID = ((try? AIILanes.load(home: home)) ?? nil)?.id(for: app)?.rawValue
        observed.logs = recentProblems(naming: [app.rawValue] + (laneID.map { [$0] } ?? []), in: [
            (home.sewnLogFile, RunRecord.load(home.sewnRunRecord)?.startedAt),
            (home.threadLogFile, RunRecord.load(home.threadRunRecord)?.startedAt),
        ])
        return observed
    }

    static func checks(_ app: AIIApp, home: AIIHome, observed: Observations) -> [DoctorCheck] {
        let name = app.rawValue
        var checks: [DoctorCheck] = []

        // The manifest.
        guard let lanes = (try? AIILanes.load(home: home)) ?? nil else {
            return [.fail("manifest", "no lanes manifest at \(tilde(home.lanesFile))", fix: "aii lanes add \(name)")]
        }
        guard let lane = lanes.lane(for: app) else {
            return [.fail("manifest", "\(name) isn't in the lanes manifest", fix: "aii lanes add \(name)")]
        }
        guard lane.owner.isLaneOwner(for: app) else {
            return [.fail("manifest", "owner \(lane.owner) is neither aii-local nor local-\(name)",
                          fix: "aii lanes owner \(name) aii-local")]
        }
        checks.append(.pass("manifest", "\(lane.displayName) · owner \(lane.owner) · registered by "
                            + "\(lane.registeredBy.displayName(in: home)) \(Stamp.minute(lane.registeredAt))"))

        // The secret.
        do {
            guard try home.readSecret(for: app) != nil else {
                return checks + [.fail("secret", "secrets/\(name) is missing", fix: "aii lanes add \(name) writes it")]
            }
            checks.append(.pass("secret", "secrets/\(name) · 0600, 64 hex"))
        } catch {
            return checks + [.fail("secret", AIIFailure.sentence("\(error)"), fix: "aii lanes add \(name) writes a missing one")]
        }

        // The lane id.
        if let key = try? AIIDeviceKey.load(home: home), AIILanes.derive(app: app, from: key) == lane.id {
            checks.append(.pass("lane id", "\(lane.id) · derived from this Mac's device key"))
        } else {
            checks.append(.pass("lane id", "\(lane.id) · registered under device key \(lane.derivedFrom); the id stays"))
        }

        // Admission.
        for (server, verdict) in [("Sewn", observed.sewn), ("Thread", observed.thread)] {
            switch verdict {
            case .ours: continue
            case .down: return checks + [.fail("admission", "\(server) isn't running", fix: "aii start")]
            case .stale:
                return checks + [.fail("admission", "\(server) doesn't know \(name)'s secret yet",
                                       fix: "run this again in two seconds; if it persists, aii restart")]
            case .open:
                return checks + [.fail("admission", "\(server) runs open, with no lanes", fix: "aii restart")]
            }
        }
        checks.append(.pass("admission", "Sewn and Thread prove \(name)'s secret"))

        // Thread's view.
        var documents = 0
        switch observed.stats {
        case .success(let stats):
            guard stats.lane == lane.id else {
                return checks + [.fail("thread", "Thread files \(name) in lane \(stats.lane), not \(lane.id)",
                                       fix: "aii restart thread")]
            }
            documents = stats.documents
            checks.append(.pass("thread", "\(stats.documents) document\(stats.documents == 1 ? "" : "s") in \(stats.groups) group\(stats.groups == 1 ? "" : "s") "
                                + "under \(stats.owners) owner\(stats.owners == 1 ? "" : "s")"))
        case .failure(let error):
            return checks + [.fail("thread", AIIFailure.sentence("\(error)"), fix: "aii logs thread")]
        case nil:
            return checks + [.fail("thread", "Thread wasn't read", fix: "aii start")]
        }

        // Groups and records, under the lane's owner.
        guard case .success(let inspection)? = observed.inspection else {
            if case .failure(let error)? = observed.inspection {
                checks.append(.fail("groups", AIIFailure.sentence("\(error)"), fix: "aii logs thread"))
            }
            return checks
        }
        let unprefixed = inspection.groups.filter { AIIRecord.parseGroupID($0.id)?.app != app }
        // Every document the owner holds was sampled, so the sample counts them.
        let grouped = inspection.groups.map(\.documents).reduce(0, +)
        if let first = unprefixed.first {
            checks.append(.fail("groups", "\(unprefixed.count) group\(unprefixed.count == 1 ? " isn't" : "s aren't") named for \(name), such as \(first.id)",
                                fix: "file into \(name)-<group>; AIIRecord.Group does it"))
        } else if inspection.sampledAll, grouped < inspection.sample.count {
            checks.append(.fail("groups", "\(inspection.sample.count - grouped) of \(inspection.owner)'s documents have no group",
                                fix: "file them again into one of \(name)'s groups"))
        } else {
            let ids = inspection.groups.map(\.id)
            checks.append(.pass("groups", ids.isEmpty ? "none yet under \(inspection.owner)"
                                    : "\(ids.count) under \(inspection.owner): \(ids.prefix(4).joined(separator: ", "))\(ids.count > 4 ? ", …" : "")"))
        }

        let sample = inspection.sample
        let notRecords = sample.filter { !$0.isRecord }
        let otherApps = sample.filter { $0.isRecord && $0.recordApp != app }
        let misfiled = sample.filter { $0.isRecord && $0.recordApp == app && !$0.idMatches }
        if let first = notRecords.first {
            checks.append(.fail("records", "\(notRecords.count) of \(sample.count) sampled documents aren't aii-record/1 envelopes, such as \(first.documentID)",
                                fix: "file them as AIIRecordable values or AIIDocuments"))
        } else if let first = otherApps.first {
            checks.append(.fail("records", "\(otherApps.count) carry another app's envelope, such as \(first.documentID)",
                                fix: "file each app's records in its own lane"))
        } else if let first = misfiled.first {
            checks.append(.fail("records", "\(misfiled.count) are filed under an id other than their envelope's <app>/<kind>/<id>, such as \(first.documentID)",
                                fix: "file through AIIDocument, which sets the id"))
        } else if sample.isEmpty {
            checks.append(.pass("records", "none yet under \(inspection.owner)"))
        } else {
            let kinds = Set(sample.compactMap(\.kind)).sorted()
            checks.append(.pass("records", "\(sample.count)\(inspection.sampledAll ? "" : " sampled") · all aii-record/1 · \(kinds.joined(separator: ", "))"))
        }

        // The owner.
        if sample.isEmpty, documents > 0 {
            checks.append(.fail("owner", "the lane holds \(documents) documents, none under \(inspection.owner), whom Sewn answers as",
                                fix: "aii lanes owner \(name) <their owner>, or file them again under \(inspection.owner)"))
        } else {
            let memory = inspection.groups.contains { $0.id == "\(name)-memory-\(inspection.owner)" }
            checks.append(.pass("owner", "Sewn answers \(name) as \(inspection.owner) without an account"
                                + (memory ? " · memory in \(name)-memory-\(inspection.owner)" : "")))
        }

        // The logs.
        if let last = observed.logs.last {
            checks.append(.fail("logs", "\(observed.logs.count) recent problem\(observed.logs.count == 1 ? "" : "s") name \(name): \(last)",
                                fix: "aii logs"))
        } else {
            checks.append(.pass("logs", "nothing recent names \(name)"))
        }
        return checks
    }

    /// The last few lines of each log that name one of `names` and report a refusal, an
    /// error or a dropped write. With a start time, only lines stamped since then count: what
    /// an earlier server logged was fixed or is gone.
    static func recentProblems(naming names: [String], in logs: [(file: URL, since: Date?)], limit: Int = 3) -> [String] {
        let words = ["error", "refused", "dropped", "failed", "denied"]
        let format = ISO8601DateFormatter()
        var found: [String] = []
        for (file, since) in logs {
            for line in StudioBackend.tail(file, lines: 2_000) {
                let lower = line.lowercased()
                guard names.contains(where: { lower.contains($0.lowercased()) }),
                      words.contains(where: { lower.contains($0) }) else { continue }
                if let since, (stamp(line, format).map { $0 < since } ?? true) { continue }
                found.append(String(line.trimmingCharacters(in: .whitespaces).prefix(160)))
            }
        }
        return Array(found.suffix(limit))
    }

    /// The time a server's log line starts with: `2026-10-16T16:10:08-0700`.
    static func stamp(_ line: String, _ format: ISO8601DateFormatter = ISO8601DateFormatter()) -> Date? {
        guard let first = line.split(separator: " ", maxSplits: 1).first else { return nil }
        return format.date(from: String(first))
    }
}
