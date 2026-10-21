//
//  Render.swift
//  AIICLI
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: What `aii status` knows, gathered once (StatusReport), and the lines it prints.
//  OUT:  `StatusReport.gather()`, the JSON report (`--json`), and `Render.status`: one row
//        per fact, a ten-column label, `✓ ✗ · →`.
//  PIN:  Rendering is pure — a report in, lines out — so tests compare strings and the
//        studio draws the same rows. A row that has a fix names it after `→`.
//

import AII
import Foundation

struct StatusReport: Codable, Equatable {
    struct Install: Codable, Equatable {
        var summary: String
        var source: String
        var installedBy: String
        var appVersion: String
        var contract: Int
        var sha256: String
        var installedAt: Date
        var checkout: String?
        var commit: String?
        var configuration: String?
    }

    struct Server: Codable, Equatable {
        var role: String
        /// `up`, `down`, `starting`, or why it is unhealthy.
        var state: String
        var healthy: Bool
        var detail: String?
        var pid: Int32?
        var http: Int
        var grpc: Int
        var verified: Bool
        var contract: Int?
        var binary: String?
        var launchedBy: String?
        var startedAt: Date?
        /// Thread only: the embedder's phase.
        var embedder: String?
    }

    struct Holder: Codable, Equatable {
        var identity: String
        var pinned: Bool
    }

    struct Model: Codable, Equatable {
        var role: String
        var id: String
        var revision: String?
        /// `installed`, `absent`, `downloading`, `failed`, or what Sewn said.
        var state: String
        var progress: Double?
        var kept: Bool
    }

    /// A provider key the stack holds (never its value): whether one is set, where it came
    /// from and who wrote it.
    struct ProviderKey: Codable, Equatable {
        var name: String
        var set: Bool
        var source: String?
        var writtenBy: String?
        var updatedAt: Date?
    }

    var home: String
    var layout: Int?
    var provisionedBy: String?
    var install: Install?
    /// An AIIServer sits in aii/bin with no install.json this aii can read.
    var installUnreadable: Bool = false
    /// The contract this aii speaks.
    var contract: Int
    var servers: [Server]
    var holders: [Holder]
    var lanes: [String]
    /// Nil when Sewn didn't list them; `modelsProblem` says why.
    var models: [Model]?
    var modelsProblem: String?
    /// The provider keys in keys/providers.json, masked to their existence.
    var keys: [ProviderKey] = []
    /// Whether aii.env holds a Supabase project (URL and anon key both).
    var supabase: Bool = false

    var sewnUp: Bool { servers.first { $0.role == "sewn" }?.healthy ?? false }

    /// Everything, read without starting or holding anything.
    static func gather(home: AIIHome = Stack.home) async -> StatusReport {
        let status = await AIISupervisor(identity: .stack, home: home, policy: .standard, hold: .none).inspect()
        let holders = AIILeases(home: home).live().map { Holder(identity: $0.identity.rawValue, pinned: $0.pinned) }
        let (models, problem) = await listModels(home: home, sewnUp: status.sewn.isUp)
        var report = StatusReport(home: home, status: status, holders: holders, lanes: home.registeredApps(), models: models)
        report.modelsProblem = problem
        report.keys = providerKeys(ProviderKeyStore(home: home).records())
        let environment = EnvFile.read(home.aiiEnvFile)
        report.supabase = !(environment["SUPABASE_URL"] ?? "").isEmpty && !(environment["SUPABASE_ANON_KEY"] ?? "").isEmpty
        return report
    }

    /// One entry per provider the stack knows, set or not, never a value.
    static func providerKeys(_ records: [String: ProviderKeyRecord]) -> [ProviderKey] {
        [ProviderKeyStore.mistralAPIKey, ProviderKeyStore.tinkerAPIKey].map { name in
            if let record = records[name], !record.value.isEmpty {
                return ProviderKey(name: name, set: true, source: record.source.rawValue, writtenBy: record.writtenBy.rawValue,
                                   updatedAt: record.updatedAt)
            }
            return ProviderKey(name: name, set: false)
        }
    }

    /// The models Sewn lists, or why there are none.
    static func listModels(home: AIIHome, sewnUp: Bool) async -> ([AIIModelState]?, String?) {
        guard sewnUp else { return (nil, "Sewn is down") }
        do {
            return (try await AIIClient(identity: .stack, home: home).models(), nil)
        } catch {
            return (nil, "Sewn didn't list them: \(AIIFailure.sentence("\(error)"))")
        }
    }

    init(home: AIIHome, status: AIIStatus, holders: [Holder], lanes: [AIIApp], models: [AIIModelState]?) {
        self.home = PrivateFile.path(home.root)
        let layout = home.layout()
        self.layout = layout?.version
        self.provisionedBy = layout.map { $0.createdBy.isStack ? "the aii command" : $0.createdBy.displayName(in: home) }
        self.installUnreadable = status.install == nil && PrivateFile.exists(home.serverBinary)
        self.install = status.install.map { record in
            Install(summary: record.summary, source: record.source.rawValue, installedBy: record.installedBy.rawValue,
                    appVersion: record.appVersion, contract: record.contract, sha256: record.sha256,
                    installedAt: record.installedAt, checkout: record.checkout?.path, commit: record.checkout?.commit,
                    configuration: record.checkout?.configuration)
        }
        self.contract = AIIContract.version
        self.servers = status.servers.map { detail in
            let state: String
            switch detail.state {
            case .up: state = "up"
            case .stopped: state = "down"
            case .starting: state = "starting"
            case .unhealthy(let why): state = why
            }
            return Server(role: detail.role.rawValue, state: state, healthy: detail.isUp, detail: detail.detail,
                          pid: detail.pid, http: detail.ports.http, grpc: detail.ports.grpc, verified: detail.verified,
                          contract: detail.contract, binary: detail.binary, launchedBy: detail.launchedBy?.rawValue,
                          startedAt: detail.startedAt,
                          embedder: detail.role == .thread ? status.embedder.map(Self.embedder) : nil)
        }
        self.holders = holders
        self.lanes = lanes.map(\.rawValue)
        self.models = models.map { states in
            AIIModels.all.map { entry in
                let found = states.first { $0.id == entry.id }
                let (state, progress): (String, Double?)
                switch found?.disk {
                case .installed: (state, progress) = ("installed", nil)
                case .absent, nil: (state, progress) = ("absent", nil)
                case .downloading(let fraction): (state, progress) = ("downloading", fraction)
                case .failed(let reason): (state, progress) = ("failed" + (reason.map { ": \($0)" } ?? ""), nil)
                case .unknown(let raw): (state, progress) = (raw, nil)
                }
                return Model(role: entry.role.rawValue, id: entry.id, revision: entry.revision, state: state,
                             progress: progress, kept: AIIModels.kept.contains(entry.id))
            }
        }
    }

    init(home: String, layout: Int?, provisionedBy: String?, install: Install?, contract: Int, servers: [Server],
         holders: [Holder], lanes: [String], models: [Model]?) {
        self.home = home
        self.layout = layout
        self.provisionedBy = provisionedBy
        self.install = install
        self.contract = contract
        self.servers = servers
        self.holders = holders
        self.lanes = lanes
        self.models = models
    }

    static func embedder(_ state: ThreadEmbedderState) -> String {
        var text = state.phase.rawValue
        if let progress = state.progress, state.phase == .downloading { text += " \(Int(progress * 100))%" }
        if state.needsRebuild { text += " · index \(state.index?.rawValue ?? "?")" }
        return text
    }

    func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

enum Render {
    static func row(_ label: String, _ value: String) -> String {
        label.padding(toLength: 10, withPad: " ", startingAt: 0) + value
    }

    static func status(_ report: StatusReport) -> [String] {
        var rows: [String] = []
        if let layout = report.layout {
            rows.append(row("home", "\(tilde(report.home)) · layout \(layout)" + (report.provisionedBy.map { ", provisioned by \($0)" } ?? "")))
        } else {
            rows.append(row("home", "\(tilde(report.home)) · not provisioned → aii start, or launch a Rao app"))
        }
        rows.append(row("install", report.installUnreadable
            ? "an AIIServer whose install.json this aii can't read → aii install"
            : install(report.install)))
        rows.append(row("contract", contract(report)))
        for server in report.servers { rows.append(self.server(server)) }
        rows.append(row("held by", holders(report.holders)))
        rows.append(row("lanes", report.lanes.isEmpty ? "none" : report.lanes.joined(separator: ", ")))
        rows.append(row("keys", keys(report.keys, supabase: report.supabase)))
        rows.append(row("models", report.models.map { models($0) } ?? "(\(report.modelsProblem ?? "Sewn is down"))"))
        return rows
    }

    /// `Mistral ✓ (ambient) · Tinker none · Supabase ✓`, or the way to add a key when there is none.
    static func keys(_ keys: [StatusReport.ProviderKey], supabase: Bool) -> String {
        guard keys.contains(where: \.set) || supabase else { return "none → aii keys set mistral, or aii setup" }
        var parts = keys.map { key in
            let label = key.name == ProviderKeyStore.tinkerAPIKey ? "Tinker" : key.name == ProviderKeyStore.mistralAPIKey ? "Mistral" : key.name
            return key.set ? "\(label) ✓" + (key.writtenBy.map { " (\($0))" } ?? "") : "\(label) none"
        }
        parts.append("Supabase \(supabase ? "✓" : "none")")
        return parts.joined(separator: " · ")
    }

    static func install(_ install: StatusReport.Install?) -> String {
        guard let install else { return "none → aii install, or launch a Rao app" }
        if install.source == AIIInstallSource.local.rawValue {
            var text = "Your build @ \(install.commit ?? "unknown")"
            if let checkout = install.checkout { text += " from \(tilde(checkout))" }
            if let configuration = install.configuration { text += " · \(configuration)" }
            return text + " · \(Stamp.minute(install.installedAt))"
        }
        return "Installed by \(install.appVersion) · \(Stamp.minute(install.installedAt))"
    }

    static func contract(_ report: StatusReport) -> String {
        guard let install = report.install else { return "this aii speaks \(report.contract)" }
        let text = "\(install.contract) · this aii speaks \(report.contract)"
        if install.contract < report.contract {
            return text + (install.source == AIIInstallSource.local.rawValue ? " → aii update" : " → aii install")
        }
        if install.contract > report.contract { return text + " → this aii is older: Scripts/install-cli.sh" }
        return text
    }

    static func server(_ server: StatusReport.Server) -> String {
        let label = server.role == "sewn" ? "Sewn" : "Thread"
        var parts: [String]
        switch server.state {
        case "up":
            parts = ["✓ up"]
            if let pid = server.pid { parts.append("pid \(pid)") }
            parts.append("http \(server.http) grpc \(server.grpc)")
            parts.append(server.verified ? "verified" : "unproven")
            if let startedAt = server.startedAt { parts.append("since \(Stamp.time(startedAt))") }
            if let embedder = server.embedder { parts.append("embedder \(embedder)") }
            return row(label, parts.joined(separator: " · "))
        case "down":
            parts = ["✗ down"]
            if let detail = server.detail { parts.append(detail) }
            return row(label, parts.joined(separator: " · ") + (server.detail == nil ? " → aii start" : " → aii logs \(server.role)"))
        case "starting":
            return row(label, "… starting · http \(server.http) grpc \(server.grpc)")
        default:
            return row(label, "✗ \(server.state) → aii logs \(server.role)")
        }
    }

    static func holders(_ holders: [StatusReport.Holder]) -> String {
        guard !holders.isEmpty else { return "nobody" }
        return holders.map { $0.identity + ($0.pinned ? " (pinned)" : "") }.joined(separator: ", ")
    }

    static func models(_ models: [StatusReport.Model]) -> String {
        let missing = models.filter { $0.state != "installed" }.map(\.role)
        let text = "\(models.count - missing.count) of \(models.count) pinned on this Mac"
        return missing.isEmpty ? text : text + " · missing " + missing.joined(separator: ", ")
    }
}
