//
//  Keys.swift
//  AIICLI
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: `aii keys`: the provider keys the stack holds for every app, and the Supabase
//        project an app with accounts ships with. Listing them masked, setting one from a
//        hidden prompt or stdin, removing one, and the Supabase pair.
//  OUT:  `list` (the default), `set`, `remove`, `supabase`.
//  PIN:  Provider keys go to ~/.rao/keys/providers.json, which Sewn and Thread read on
//        every call: a change is live, nothing restarts. The Supabase pair goes to
//        ~/.rao/aii/aii.env, which Sewn reads once at start: a change says `aii restart
//        sewn`. A key is never an argument (it would land in shell history); nothing printed
//        is ever a secret. A key an account handed over is kept unless --force.
//

import AII
import ArgumentParser
import Foundation

struct KeysCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keys",
        abstract: "The provider keys and the Supabase project the stack holds: list, set one, remove one.",
        subcommands: [List.self, Set.self, Remove.self, Supabase.self],
        defaultSubcommand: List.self)

    enum Provider: String, CaseIterable, ExpressibleByArgument {
        case mistral, tinker

        var keyName: String {
            switch self {
            case .mistral: return ProviderKeyStore.mistralAPIKey
            case .tinker: return ProviderKeyStore.tinkerAPIKey
            }
        }

        var label: String {
            switch self {
            case .mistral: return "Mistral"
            case .tinker: return "Tinker"
            }
        }
    }

    /// The stack's store, never `.process`: the command decides the home, not its environment.
    static func store(home: AIIHome = Stack.home) -> ProviderKeyStore { ProviderKeyStore(home: home) }

    /// The last four characters, the rest hidden; too short to show anything, dots.
    static func mask(_ value: String) -> String {
        value.count >= 8 ? "…" + value.suffix(4) : "····"
    }

    /// What `list` prints: a row per provider, the Supabase pair, and where each lands.
    static func rows(records: [String: ProviderKeyRecord], environment: [String: String], home: AIIHome) -> [String] {
        var lines: [String] = []
        for provider in Provider.allCases {
            let head = provider.keyName.padding(toLength: 18, withPad: " ", startingAt: 0)
            if let record = records[provider.keyName], !record.value.isEmpty {
                lines.append(head + "\(mask(record.value))  \(record.source.rawValue)  \(record.writtenBy.rawValue)  \(Stamp.minute(record.updatedAt))")
            } else {
                lines.append(head + "none → aii keys set \(provider.rawValue)")
            }
        }
        let url = environment["SUPABASE_URL"] ?? ""
        let anon = environment["SUPABASE_ANON_KEY"] ?? ""
        if url.isEmpty && anon.isEmpty {
            lines.append("SUPABASE_URL".padding(toLength: 18, withPad: " ", startingAt: 0) + "none · no accounts layer → aii keys supabase --url … --anon-key …")
        } else {
            lines.append("SUPABASE_URL".padding(toLength: 18, withPad: " ", startingAt: 0) + (url.isEmpty ? "none" : url) + "  aii.env")
            lines.append("SUPABASE_ANON_KEY".padding(toLength: 18, withPad: " ", startingAt: 0) + (anon.isEmpty ? "none" : mask(anon)) + "  aii.env")
        }
        lines.append("\(tilde(home.providersFile)) is read per call: a change is live, no restart · \(tilde(home.aiiEnvFile)) is read by Sewn at start")
        return lines
    }

    /// Why `set` won't write over `existing`: a key the person's account handed over is
    /// theirs to replace on purpose only.
    static func refusal(existing: ProviderKeyRecord?, force: Bool, provider: Provider) -> AIIFailure? {
        guard let existing, existing.source == .account, !existing.value.isEmpty, !force else { return nil }
        return .usage("\(provider.keyName) came from an account (written by \(existing.writtenBy.rawValue))",
                      hint: "pass --force to replace it; the app writes its key again at sign-in")
    }

    /// An `https://` URL with a host, as Supabase hands them out.
    static func supabaseURL(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "https", let host = url.host, !host.isEmpty else {
            throw AIIFailure.usage("\"\(text)\" is not a Supabase project URL", hint: "https://<project>.supabase.co")
        }
        return trimmed
    }

    static func sewnIsUp(home: AIIHome = Stack.home) async -> Bool {
        await AIISupervisor(identity: .stack, home: home, policy: .standard, hold: .none).inspect().sewn.isUp
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "Each provider key, masked, with its source and writer; the Supabase pair; where each lands.")

        func run() async throws {
            await guarded {
                let home = Stack.home
                for line in KeysCommand.rows(records: KeysCommand.store(home: home).records(),
                                             environment: EnvFile.read(home.aiiEnvFile), home: home) {
                    print(line)
                }
            }
        }
    }

    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Set a provider key from a hidden prompt, or the first line of stdin; live for both servers at once.")

        @Argument(help: "mistral or tinker.")
        var provider: Provider

        @Flag(name: .long, help: "Read the key from the first line of stdin instead of asking.")
        var stdin = false

        @Flag(name: .long, help: "Replace a key your account handed over.")
        var force = false

        func run() async throws {
            await guarded {
                let home = Stack.home
                let store = KeysCommand.store(home: home)
                if let refusal = KeysCommand.refusal(existing: store.record(for: provider.keyName), force: force, provider: provider) {
                    throw refusal
                }
                let value = stdin
                    ? Swift.readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    : TerminalPrompt.readSecret("\(provider.label) API key: ")
                guard let value else {
                    throw AIIFailure.usage("no terminal to ask on", hint: "pbpaste | aii keys set \(provider.rawValue) --stdin")
                }
                guard !value.isEmpty else {
                    throw AIIFailure.usage("an empty key sets nothing", hint: "aii keys remove \(provider.rawValue) --yes")
                }
                try store.write(provider.keyName, value: value, source: .typed, writtenBy: .stack)
                print("\(provider.keyName) set (\(KeysCommand.mask(value))) in \(tilde(home.providersFile)) · live for Sewn and Thread")
            }
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "remove",
            abstract: "Remove a provider key from this Mac; the servers fall back to on device.")

        @Argument(help: "mistral or tinker.")
        var provider: Provider

        @Flag(name: .long, help: "Remove it: nothing is removed without this.")
        var yes = false

        func run() async throws {
            await guarded {
                let home = Stack.home
                let store = KeysCommand.store(home: home)
                guard let existing = store.record(for: provider.keyName) else {
                    throw AIIFailure.missing("no \(provider.keyName) in \(tilde(home.providersFile))")
                }
                guard yes else { throw AIIFailure.usage("pass --yes to remove \(provider.keyName)") }
                try store.remove(provider.keyName)
                print("removed \(provider.keyName) · the servers run on device without it")
                if existing.source == .account {
                    note("keys: it was \(existing.writtenBy.displayName(in: home))'s account key; the app writes it again at sign-in")
                }
            }
        }
    }

    struct Supabase: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "supabase",
            abstract: "The Supabase project for an app with accounts: its URL and anon key into aii.env; Sewn reads it at start.")

        @Option(name: .long, help: "The project URL: https://<project>.supabase.co")
        var url: String?

        @Option(name: .customLong("anon-key"), help: "The anon public key, never the service-role key.")
        var anonKey: String?

        @Flag(name: .long, help: "Remove both values instead; needs --yes.")
        var remove = false

        @Flag(name: .long, help: "With --remove: remove them. Nothing is removed without this.")
        var yes = false

        func run() async throws {
            await guarded {
                let home = Stack.home
                let changed: Bool
                if remove {
                    guard yes else { throw AIIFailure.usage("pass --yes to remove the Supabase project from aii.env") }
                    changed = try AIIEnvironmentFile.update(home: home) { values in
                        values["SUPABASE_URL"] = nil
                        values["SUPABASE_ANON_KEY"] = nil
                    }
                    print(changed ? "removed SUPABASE_URL, SUPABASE_ANON_KEY from \(tilde(home.aiiEnvFile))" : "\(tilde(home.aiiEnvFile)) held no Supabase project")
                } else {
                    guard url != nil || anonKey != nil else { throw AIIFailure.usage("pass --url and/or --anon-key") }
                    let url = try url.map(KeysCommand.supabaseURL)
                    let anonKey = anonKey?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let anonKey, anonKey.isEmpty { throw AIIFailure.usage("an empty anon key sets nothing") }
                    changed = try AIIEnvironmentFile.update(home: home) { values in
                        if let url { values["SUPABASE_URL"] = url }
                        if let anonKey { values["SUPABASE_ANON_KEY"] = anonKey }
                    }
                    let names = [url.map { _ in "SUPABASE_URL" }, anonKey.map { _ in "SUPABASE_ANON_KEY" }].compactMap { $0 }
                    print("→ \(tilde(home.aiiEnvFile)): \(names.joined(separator: ", ")) \(changed ? "set" : "already set")")
                }
                if changed, await KeysCommand.sewnIsUp(home: home) {
                    print("→ aii restart sewn (Sewn reads aii.env once, at start)")
                }
            }
        }
    }
}
