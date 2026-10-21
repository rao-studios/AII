//
//  Checks.swift
//  AIICLI
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The doctor's checks: the home, its secrets, the device key, the provider keys and
//        the Supabase project, the lanes, the installed build and the rule that vouches for
//        it, the contract, both servers, the models the index needs, and this command on PATH.
//  OUT:  `DoctorCheck`s, each a name, a verdict, a detail and — when it fails — the fix.
//  PIN:  Nothing here writes anything. A failed check says what is wrong and the shortest
//        way to fix it. A bundled build is checked against Rao's Developer ID whatever this
//        command was built as, because that is what a release app checks. No key and no
//        Supabase project are states, not faults: an index with neither runs on device.
//

import AII
import Foundation

struct DoctorCheck: Equatable {
    var name: String
    var ok: Bool
    var detail: String
    var fix: String?

    static func pass(_ name: String, _ detail: String) -> DoctorCheck { .init(name: name, ok: true, detail: detail) }
    static func fail(_ name: String, _ detail: String, fix: String? = nil) -> DoctorCheck {
        .init(name: name, ok: false, detail: detail, fix: fix)
    }

    var line: String { "  \(ok ? "✓" : "✗") \(name): \(detail)" + (fix.map { " → \($0)" } ?? "") }
}

enum Checks {

    /// Every check, in the order they print.
    static func all(home: AIIHome) async -> [DoctorCheck] {
        let installer = AIIInstaller(home: home)
        let status = await AIISupervisor(identity: .stack, home: home, policy: .standard, hold: .none).inspect()
        let (models, modelsProblem) = await StatusReport.listModels(home: home, sewnUp: status.sewn.isUp)
        let record = installer.installedRecord()
        var checks = [self.home(home), secrets(home), deviceKey(home), providerKeys(home), environment(home), lanes(home), install(home)]
        if let record {
            checks.append(source(home, record: record))
            checks.append(contract(record))
        }
        checks.append(server(status.sewn))
        checks.append(server(status.thread, embedder: status.embedder))
        checks.append(self.models(models, problem: modelsProblem))
        checks.append(command(path: ProcessInfo.processInfo.environment["PATH"] ?? "", home: home))
        return checks
    }

    static func home(_ home: AIIHome) -> DoctorCheck {
        guard PrivateFile.exists(home.root) else {
            return .fail("home", "\(tilde(home.root)) does not exist", fix: "aii start, or launch a Rao app")
        }
        do { try PrivateFile.verifyPrivate(home.root) } catch {
            return .fail("home", AIIFailure.sentence("\(error)"), fix: "chmod 700 \(tilde(home.root))")
        }
        guard let layout = home.layout() else {
            return .fail("home", "\(tilde(home.root)) has no layout.json", fix: "aii start, or launch a Rao app")
        }
        guard layout.version == AIIContract.layoutVersion else {
            return .fail("home", "layout \(layout.version); this aii reads layout \(AIIContract.layoutVersion)", fix: "aii reset")
        }
        return .pass("home", "\(tilde(home.root)) · layout \(layout.version) · 0700")
    }

    static func secrets(_ home: AIIHome) -> DoctorCheck {
        let identities = [StackIdentity.stack] + home.registeredApps().map(StackIdentity.app)
        var found: [String] = []
        var problems: [String] = []
        for identity in identities {
            do {
                if try home.readSecret(for: identity) != nil {
                    found.append(identity.rawValue)
                } else if identity.app != nil {
                    problems.append("\(identity.rawValue) has none")
                }
            } catch {
                problems.append("\(identity.rawValue): \(AIIFailure.sentence("\(error)"))")
            }
        }
        if !problems.isEmpty {
            return .fail("secrets", problems.joined(separator: "; "), fix: "aii lanes add <name> writes a missing one")
        }
        guard found.contains(StackIdentity.stackRawValue) else {
            return .fail("secrets", "the stack has no secret", fix: "aii start")
        }
        return .pass("secrets", "\(found.joined(separator: ", ")) · 0600, 64 hex")
    }

    static func deviceKey(_ home: AIIHome) -> DoctorCheck {
        do {
            guard let key = try AIIDeviceKey.load(home: home) else {
                return .fail("device key", "none yet", fix: "aii start, or launch a Rao app")
            }
            return .pass("device key", "fingerprint \(key.fingerprint)")
        } catch {
            return .fail("device key", AIIFailure.sentence("\(error)"))
        }
    }

    /// keys/providers.json: absent is a supported state; a file that is open to others or
    /// doesn't decode is not, because both servers would read it as no keys.
    static func providerKeys(_ home: AIIHome) -> DoctorCheck {
        let store = ProviderKeyStore(home: home)
        let none = "none yet · the index runs on device · aii keys set mistral adds one"
        guard PrivateFile.exists(home.providersFile) else { return .pass("keys", none) }
        do {
            let records = try store.checkedRecords().filter { !$0.value.value.isEmpty }
            guard !records.isEmpty else { return .pass("keys", none) }
            let detail = records.keys.sorted().map { name in
                let record = records[name]!
                return "\(name) (\(record.source.rawValue), \(record.writtenBy.rawValue))"
            }.joined(separator: ", ")
            return .pass("keys", "\(detail) · 0600 · read per call")
        } catch let error as PrivateFileError {
            return .fail("keys", AIIFailure.sentence("\(error)"), fix: "chmod 600 \(tilde(home.providersFile))")
        } catch {
            return .fail("keys", AIIFailure.sentence("\(error)"), fix: "aii keys set mistral writes it again")
        }
    }

    /// aii/aii.env: the Supabase project an app with accounts ships with. Absent is a
    /// supported state; half a pair, a denied key or an open file is not.
    static func environment(_ home: AIIHome) -> DoctorCheck {
        guard PrivateFile.exists(home.aiiEnvFile) else {
            return .pass("supabase", "none · no accounts layer · shipping an app with accounts? aii keys supabase --url … --anon-key …")
        }
        do { try PrivateFile.verifyPrivate(home.aiiEnvFile) } catch {
            return .fail("supabase", AIIFailure.sentence("\(error)"), fix: "chmod 600 \(tilde(home.aiiEnvFile))")
        }
        let values = EnvFile.read(home.aiiEnvFile)
        let denied = values.keys.filter { AIIEnvironmentFile.deniedKeys.contains($0) }.sorted()
        if let first = denied.first {
            return .fail("supabase", "aii.env holds \(denied.joined(separator: ", ")), which Sewn ignores there",
                         fix: first == AIIHome.environmentKey ? "remove it from aii.env" : "aii keys set \(first == ProviderKeyStore.tinkerAPIKey ? "tinker" : "mistral"), then remove it from aii.env")
        }
        let url = values["SUPABASE_URL"] ?? ""
        let anon = values["SUPABASE_ANON_KEY"] ?? ""
        switch (url.isEmpty, anon.isEmpty) {
        case (true, true):
            return .pass("supabase", "none · no accounts layer · shipping an app with accounts? aii keys supabase --url … --anon-key …")
        case (false, true):
            return .fail("supabase", "aii.env has SUPABASE_URL but no SUPABASE_ANON_KEY", fix: "aii keys supabase --anon-key …")
        case (true, false):
            return .fail("supabase", "aii.env has SUPABASE_ANON_KEY but no SUPABASE_URL", fix: "aii keys supabase --url …")
        case (false, false):
            return .pass("supabase", "\(URL(string: url)?.host ?? url) · read by Sewn at start")
        }
    }

    /// The lanes manifest against secrets/: every registered app listed with a secret.
    /// A secret with no entry is an unlisted lane, which a later AII, admitting only the
    /// lanes the manifest lists, would refuse.
    static func lanes(_ home: AIIHome) -> DoctorCheck {
        let apps = home.registeredApps()
        guard !apps.isEmpty else { return .fail("lanes", "no app is registered", fix: "launch a Rao app, or aii lanes add <name>") }
        guard let lanes = (try? AIILanes.load(home: home)) ?? nil else {
            return .fail("lanes", "no lanes manifest at \(tilde(home.lanesFile))", fix: "aii start writes one")
        }
        let unlisted = apps.filter { lanes.lane(for: $0) == nil }
        if !unlisted.isEmpty {
            return .fail("lanes", "\(unlisted.map(\.rawValue).joined(separator: ", ")) \(unlisted.count == 1 ? "has" : "have") a secret but no lane in the manifest",
                         fix: "aii lanes add \(unlisted[0].rawValue)")
        }
        let secretless = lanes.apps.filter { ((try? home.readSecret(for: $0)) ?? nil) == nil }
        if !secretless.isEmpty {
            return .fail("lanes", "\(secretless.map(\.rawValue).joined(separator: ", ")) \(secretless.count == 1 ? "has" : "have") a lane but no secret",
                         fix: "aii lanes add \(secretless[0].rawValue) writes it")
        }
        let shared = lanes.apps.filter { lanes.owner(for: $0) == .local }
        var detail = lanes.apps.map(\.rawValue).joined(separator: ", ")
        if !shared.isEmpty { detail += " · \(shared.count) under aii-local" }
        if let key = try? AIIDeviceKey.load(home: home) {
            let rekeyed = lanes.apps.filter { AIILanes.derive(app: $0, from: key) != lanes.id(for: $0) }
            if !rekeyed.isEmpty { detail += " · \(rekeyed.map(\.rawValue).joined(separator: ", ")) from an older device key" }
        }
        return .pass("lanes", detail)
    }

    static func install(_ home: AIIHome) -> DoctorCheck {
        let installer = AIIInstaller(home: home)
        guard let record = installer.installedRecord() else {
            if PrivateFile.exists(home.serverBinary) {
                return .fail("install", "an AIIServer is there, but not an install.json this aii can read", fix: "aii install")
            }
            return .fail("install", "nothing in \(tilde(home.aiiBinDirectory))", fix: "aii install, or launch a Rao app")
        }
        do {
            let found = try FileDigest.sha256(of: home.serverBinary)
            guard found == record.sha256 else {
                return .fail("install", "AIIServer no longer matches install.json", fix: "aii install")
            }
            return .pass("install", "\(tildeInText(record.summary)) · AIIServer matches install.json (\(record.sha256.prefix(8))…)")
        } catch {
            return .fail("install", AIIFailure.sentence("\(error)"), fix: "aii install")
        }
    }

    static func source(_ home: AIIHome, record: AIIInstallRecord) -> DoctorCheck {
        switch record.source {
        case .local:
            guard let found = PrivateFile.ownerAndMode(home.aiiInstallRecord), found.isRegularFile,
                  found.uid == geteuid(), found.mode == 0o600 else {
                return .fail("source", "your build's install.json isn't a private file of yours", fix: "aii install")
            }
            return .pass("source", "your build, vouched for by its 0600 record; every app keeps it")
        case .bundled:
            do {
                try SignaturePolicy.developerID(teamID: SignaturePolicy.teamID).check(home.serverBinary)
                return .pass("source", "\(record.installedBy.displayName(in: home))'s build, signed by Rao")
            } catch {
                return .fail("source", "\(record.installedBy.displayName(in: home))'s build isn't signed by Rao: a release app won't run it",
                             fix: "aii install, to use your own")
            }
        }
    }

    static func contract(_ record: AIIInstallRecord) -> DoctorCheck {
        if record.contract == AIIContract.version {
            return .pass("contract", "\(record.contract), as this aii speaks")
        }
        if record.contract < AIIContract.version {
            return .fail("contract", "the build speaks \(record.contract); this aii speaks \(AIIContract.version)",
                         fix: record.source == .local ? "aii update" : "aii install")
        }
        return .fail("contract", "the build speaks \(record.contract); this aii only \(AIIContract.version)",
                     fix: "Scripts/install-cli.sh")
    }

    static func server(_ detail: AIIStatus.ServerDetail, embedder: ThreadEmbedderState? = nil) -> DoctorCheck {
        let name = detail.role.displayName
        switch detail.state {
        case .up where detail.verified:
            var text = "up · pid \(detail.pid.map(String.init) ?? "?") · proved the stack's secret on \(detail.ports.http)"
            if let embedder {
                if embedder.phase == .failed {
                    return .fail(name, "\(text) · the embedder failed: \(embedder.error ?? "no reason given")", fix: "aii logs thread")
                }
                if embedder.needsRebuild {
                    return .fail(name, "\(text) · the index was built with another embedder", fix: "aii logs thread")
                }
                text += " · embedder \(embedder.phase.rawValue)"
            }
            return .pass(name, text)
        case .up:
            return .fail(name, "something answers on \(detail.ports.http) but can't be seen", fix: "aii restart \(detail.role.rawValue)")
        case .stopped:
            return .fail(name, "not running", fix: "aii start")
        case .starting:
            return .fail(name, "still starting", fix: "aii status in a moment")
        case .unhealthy(let why):
            return .fail(name, why, fix: "aii logs \(detail.role.rawValue)")
        }
    }

    /// The two models the index runs on must be here; the rest are an app's choice.
    static func models(_ states: [AIIModelState]?, problem: String? = nil) -> DoctorCheck {
        guard let states else {
            return .fail("models", "\(problem ?? "Sewn is down"), so they can't be listed",
                         fix: problem == nil || problem == "Sewn is down" ? "aii start" : "aii install, then aii restart")
        }
        let installed = Set(states.filter { $0.disk == .installed }.map(\.id))
        let needed = AIIModels.all.filter { AIIModels.kept.contains($0.id) }
        let missing = needed.filter { !installed.contains($0.id) }
        if let first = missing.first {
            return .fail("models", "the index needs \(missing.map(\.role.rawValue).joined(separator: " and ")), not on this Mac",
                         fix: "aii models pull \(first.role.rawValue)")
        }
        let count = AIIModels.all.filter { installed.contains($0.id) }.count
        return .pass("models", "the two the index needs are here · \(count) of \(AIIModels.all.count) pinned on this Mac")
    }

    static func command(path: String, home: AIIHome) -> DoctorCheck {
        let directories = path.split(separator: ":").map(String.init)
        let local = PrivateFile.path(AIIHome.userHomeDirectory.appendingPathComponent(".local/bin"))
        for directory in [PrivateFile.path(home.cliDirectory), local] where directories.contains(directory) {
            if FileManager.default.isExecutableFile(atPath: directory + "/aii") {
                return .pass("aii", "on PATH at \(tilde(directory + "/aii"))")
            }
        }
        if PrivateFile.exists(home.cliBinary) {
            return .fail("aii", "\(tilde(home.cliBinary)) is not on PATH", fix: "Scripts/setup.sh --add-to-path")
        }
        return .fail("aii", "not installed", fix: "Scripts/setup.sh")
    }
}
