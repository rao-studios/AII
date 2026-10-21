//
//  Setup.swift
//  AIICLI
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: `aii setup`: the first run, in one step. Provision ~/.rao, take one API key of the
//        person's choice (from the checkout's .env, a flag, or a hidden prompt), install
//        the servers unless an app already did, start them, pull the two models the index
//        needs, and end with the doctor's summary.
//  PIN:  Idempotent and removes nothing, so there is no --yes: run it again and it says
//        "already". One key is enough — Mistral or Tinker; without one the index runs on
//        device. Supabase is never asked for: it is the accounts layer an app ships with,
//        and comes from .env, the flags, or `aii keys supabase` later. Nothing printed is
//        ever a secret. Exit 0 when every step that ran succeeded; the doctor's summary at
//        the end is information, not a verdict.
//

import AII
import ArgumentParser
import Foundation

struct SetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "First run: provision ~/.rao, take your API key, install and start the servers, pull the two models.")

    @Argument(help: "The AII checkout to build from. Default: the one this aii came from, or the current folder.")
    var checkout: String?

    @Flag(name: .long, help: "Build and install the debug configuration.")
    var debug = false

    @Flag(name: .customLong("no-build"), help: "Install what the checkout already built.")
    var noBuild = false

    @Flag(name: .customLong("no-install"), help: "The home and the keys only; install nothing.")
    var noInstall = false

    @Flag(name: .customLong("no-start"), help: "Don't start the servers.")
    var noStart = false

    @Flag(name: .customLong("no-models"), help: "Don't pull the two models the index needs.")
    var noModels = false

    @Flag(name: .customLong("no-prompt"), help: "Never ask; take only what .env and the flags give.")
    var noPrompt = false

    @Flag(name: .customLong("mistral-key-stdin"), help: "Read the Mistral key from the first line of stdin.")
    var mistralKeyStdin = false

    @Option(name: .customLong("supabase-url"), help: "For an app with accounts: the Supabase project URL.")
    var supabaseURL: String?

    @Option(name: .customLong("supabase-anon-key"), help: "For an app with accounts: the Supabase anon public key.")
    var supabaseAnonKey: String?

    func run() async throws {
        await guarded {
            let home = Stack.home
            let options = SetupPlan.Options(noInstall: noInstall, noStart: noStart, noModels: noModels, noBuild: noBuild,
                                            debug: debug, noPrompt: noPrompt, mistralGiven: mistralKeyStdin,
                                            supabaseGiven: supabaseURL != nil || supabaseAnonKey != nil)

            // 1. home
            let probe = Stack.supervisor(hold: .none)
            let sewnWasUp = await probe.inspect().sewn.isUp
            _ = try await probe.prepare()
            let layout = home.layout()?.version ?? AIIContract.layoutVersion
            print("✓ " + Render.row("home", "\(tilde(home.root)) · layout \(layout)"))

            // 2. keys
            let root = try CheckoutResolver.locate(argument: checkout, verb: "setup")
            let store = KeysCommand.store(home: home)
            var envChanged = false
            if let root {
                let env = root.appendingPathComponent(".env")
                if let found = PrivateFile.ownerAndMode(env), found.mode & 0o077 != 0 {
                    note("setup: \(tilde(env)) is readable by others (mode \(String(found.mode, radix: 8))) → chmod 600 \(tilde(env))")
                }
                InstallCommand.adoptProviderKeys(from: root, home: home, indent: "  ")
                let pair = EnvFile.read(env).filter { AIIEnvironmentFile.allowedKeys.contains($0.key) && !$0.value.isEmpty }
                if !pair.isEmpty {
                    envChanged = try AIIEnvironmentFile.update(home: home) { values in
                        for (key, value) in pair where values[key] == nil { values[key] = value }
                    } || envChanged
                }
            }
            if mistralKeyStdin {
                guard let value = Swift.readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                    throw AIIFailure.usage("--mistral-key-stdin: the first line of stdin was empty")
                }
                try Self.adopt([ProviderKeyStore.mistralAPIKey: value], store: store, home: home)
            }
            if supabaseURL != nil || supabaseAnonKey != nil {
                let url = try supabaseURL.map(KeysCommand.supabaseURL)
                let anonKey = supabaseAnonKey?.trimmingCharacters(in: .whitespacesAndNewlines)
                envChanged = try AIIEnvironmentFile.update(home: home) { values in
                    if let url { values["SUPABASE_URL"] = url }
                    if let anonKey, !anonKey.isEmpty { values["SUPABASE_ANON_KEY"] = anonKey }
                } || envChanged
                print("  → \(tilde(home.aiiEnvFile)): \([url.map { _ in "SUPABASE_URL" }, anonKey.map { _ in "SUPABASE_ANON_KEY" }].compactMap { $0 }.joined(separator: ", ")) set")
            }
            let plan = SetupPlan.decide(installed: Stack.installer.installedRecord(), checkout: root,
                                        missingKey: Self.missingKey(store), missingSupabase: Self.missingSupabase(home),
                                        interactive: Terminal.isInteractive, sewnUp: sewnWasUp, options: options)
            for step in plan {
                switch step {
                case .promptKey:
                    var value = TerminalPrompt.readSecret("Mistral API key (Enter to skip): ")
                    var name = ProviderKeyStore.mistralAPIKey
                    if value?.isEmpty ?? true {
                        value = TerminalPrompt.readSecret("Tinker API key (Enter to skip): ")
                        name = ProviderKeyStore.tinkerAPIKey
                    }
                    if let value, !value.isEmpty {
                        try Self.adopt([name: value], store: store, home: home)
                    } else {
                        note("setup: no key; the index runs on device only → aii keys set mistral")
                    }
                case .noteNoKey:
                    note("setup: no key; the index runs on device only → aii keys set mistral")
                case .hintSupabase:
                    print("  → shipping an app with accounts? aii keys supabase --url … --anon-key …")
                default:
                    continue
                }
            }
            if envChanged, sewnWasUp {
                print("  → aii restart sewn (Sewn reads aii.env once, at start)")
            }
            let supabase = EnvFile.read(home.aiiEnvFile)
            print("✓ " + Render.row("keys", Render.keys(StatusReport.providerKeys(store.records()),
                                                          supabase: !(supabase["SUPABASE_URL"] ?? "").isEmpty && !(supabase["SUPABASE_ANON_KEY"] ?? "").isEmpty)))

            // 3. install, 4. start, 5. models
            for step in plan {
                switch step {
                case .install(let root, let configuration, let build):
                    try await InstallCommand.install(from: root, configuration: configuration, build: build, verb: "setup")
                case .keepInstall(let summary):
                    print("✓ " + Render.row("install", summary))
                case .noInstall:
                    note("setup: nothing installed and no AII checkout found → launch a Rao app, or aii install <checkout>")
                case .skippedInstall:
                    note("setup: --no-install; nothing is installed yet → aii install")
                case .start:
                    let supervisor = Stack.supervisor(hold: .pinned)
                    _ = try await supervisor.prepare()
                    try await supervisor.ensureRunning()
                    await printServers()
                    print("  → held by aii (pinned) until aii stop")
                case .pullModels:
                    for entry in AIIModels.all where AIIModels.kept.contains(entry.id) {
                        try await ModelsCommand.pull(entry.role)
                    }
                default:
                    continue
                }
            }

            // 6. doctor
            let checks = await Checks.all(home: home)
            for line in DoctorCommand.lines(checks).dropFirst().dropLast() { print(line) }
            let failed = checks.filter { !$0.ok }.count
            print(failed == 0 ? "setup done" : "setup done · \(failed) check\(failed == 1 ? "" : "s") still fail\(failed == 1 ? "s" : "") → aii doctor")
        }
    }

    /// A key given to setup, adopted like a checkout's: an account's key is kept and said.
    private static func adopt(_ keys: [String: String], store: ProviderKeyStore, home: AIIHome) throws {
        let outcome = try store.adopt(keys)
        for line in InstallCommand.adoptionLines(outcome, records: store.records(), home: home) { print("  " + line) }
    }

    static func missingKey(_ store: ProviderKeyStore) -> Bool {
        ProviderKeyStore.sharedKeyNames.allSatisfy { (store.record(for: $0)?.value ?? "").isEmpty }
    }

    static func missingSupabase(_ home: AIIHome) -> Bool {
        let values = EnvFile.read(home.aiiEnvFile)
        return (values["SUPABASE_URL"] ?? "").isEmpty || (values["SUPABASE_ANON_KEY"] ?? "").isEmpty
    }
}

/// What `aii setup` does, decided from what it finds: pure, so tests read it.
enum SetupPlan {
    enum Step: Equatable {
        /// Ask for one key, Mistral then Tinker, each Enter-skippable.
        case promptKey
        /// Non-interactive, nothing given: say so, with the command that adds one.
        case noteNoKey
        /// No Supabase project: one line naming the command, for apps with accounts.
        case hintSupabase
        case install(URL, configuration: String, build: Bool)
        /// Something is installed: whose build, and that it is kept.
        case keepInstall(String)
        /// Nothing installed and no checkout to build from.
        case noInstall
        /// Nothing installed; --no-install said not to.
        case skippedInstall
        case start
        case pullModels
    }

    struct Options: Equatable {
        var noInstall = false
        var noStart = false
        var noModels = false
        var noBuild = false
        var debug = false
        var noPrompt = false
        /// A key arrived by flag: nothing to ask.
        var mistralGiven = false
        var supabaseGiven = false
    }

    static func decide(installed: AIIInstallRecord?, checkout: URL?, missingKey: Bool, missingSupabase: Bool,
                       interactive: Bool, sewnUp: Bool, options: Options) -> [Step] {
        var steps: [Step] = []
        if missingKey, !options.mistralGiven {
            steps.append(interactive && !options.noPrompt ? .promptKey : .noteNoKey)
        }
        if missingSupabase, !options.supabaseGiven { steps.append(.hintSupabase) }

        var haveBuild = installed != nil
        if let installed {
            steps.append(.keepInstall(keepSummary(installed)))
        } else if let checkout, !options.noInstall {
            steps.append(.install(checkout, configuration: options.debug ? "debug" : "release", build: !options.noBuild))
            haveBuild = true
        } else {
            steps.append(options.noInstall && checkout != nil ? .skippedInstall : .noInstall)
        }
        if haveBuild, !options.noStart { steps.append(.start) }
        if !options.noModels, (haveBuild && !options.noStart) || sewnUp { steps.append(.pullModels) }
        return steps
    }

    /// What is installed, and that setup leaves it: a Rao app's build or the person's own.
    static func keepSummary(_ record: AIIInstallRecord) -> String {
        switch record.source {
        case .bundled: return "\(tildeInText(record.summary)) · kept: a Rao app's build"
        case .local: return "\(tildeInText(record.summary)) · already installed (aii update rebuilds it)"
        }
    }
}
