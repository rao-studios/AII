//
//  Install.swift
//  AIICLI
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: `aii install`: build AIIServer from an AII checkout and install it as the person's
//        own build, which every app then keeps and runs; then the checkout's .env keys into
//        keys/providers.json, each one said. And how a checkout is found.
//  IN:   A checkout: the argument, AII_CHECKOUT, the installed build's own, the one this aii
//        was built from (~/.rao/bin/aii.json), or the one this binary or the current folder
//        sits in.
//  PIN:  Never refuses while the servers run: the binary is renamed into place, so a running
//        server keeps its file, and the next restart runs the new one — said when it applies.
//        The key copy runs after the install and never fails it: the build is in place by then.
//

import AII
import ArgumentParser
import Foundation

struct InstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Build AIIServer from a checkout and install it as your build, kept by every app.")

    @Argument(help: "The AII checkout to build. Default: the one this aii came from.")
    var checkout: String?

    @Flag(name: .long, help: "Build and install the debug configuration.")
    var debug = false

    @Flag(name: .customLong("no-build"), help: "Install what the checkout already built.")
    var noBuild = false

    func run() async throws {
        await guarded {
            let root = try CheckoutResolver.resolve(argument: checkout)
            try await Self.install(from: root, configuration: debug ? "debug" : "release", build: !noBuild, verb: "install")
        }
    }

    static func install(from root: URL, configuration: String, build: Bool, verb: String) async throws {
        let home = Stack.home
        if build {
            note("\(verb): building AIIServer (\(configuration)) in \(tilde(root))")
            let built = await AIIInstaller.build(checkout: root, configuration: configuration) { note("\(verb): \($0)") }
            guard built else { throw AIIFailure.internalError("Scripts/build-servers.sh failed", hint: "its output is above") }
        }
        let outcome = try Stack.installer.installLocal(from: root, configuration: configuration)
        let record = outcome.record
        switch outcome {
        case .installed(_, let replaced):
            print("installed \(tildeInText(record.summary)) (contract \(record.contract), \(configuration)) into \(tilde(home.aiiBinDirectory))")
            print("  AIIServer \(record.sha256.prefix(8))…\(record.sha256.suffix(4))" + (replaced.map { " · replaced \(tildeInText($0.summary))" } ?? ""))
        case .alreadyCurrent:
            print("already installed: \(tildeInText(record.summary))")
        case .keptExisting:
            print("kept \(tildeInText(record.summary))")
        }
        adoptProviderKeys(from: root, home: home)
        if let running = runningPreviousBuild(home: home) {
            print("→ \(running) running the previous build: aii restart")
        }
    }

    /// The checkout's `.env` provider keys into keys/providers.json, each one said. Never
    /// throws: the build is in place by now, so a failure here is printed, not fatal.
    @discardableResult
    static func adoptProviderKeys(from root: URL, home: AIIHome, indent: String = "", now: Date = Date()) -> [String: ProviderKeyStore.Adoption] {
        let keys = ProviderKeyStore.sharedKeys(inEnvFile: root.appendingPathComponent(".env"))
        guard !keys.isEmpty else { return [:] }
        let store = ProviderKeyStore(home: home)
        do {
            let outcome = try store.adopt(keys, now: now)
            for line in adoptionLines(outcome, records: store.records(), home: home) { print(indent + line) }
            return outcome
        } catch {
            print("\(indent)→ \(tilde(home.providersFile)): not written: \(AIIFailure.sentence("\(error)"))")
            return [:]
        }
    }

    /// `→ ~/.rao/keys/providers.json: MISTRAL_API_KEY set (…k9Qz)`, one per key, sorted.
    static func adoptionLines(_ outcome: [String: ProviderKeyStore.Adoption], records: [String: ProviderKeyRecord],
                              home: AIIHome) -> [String] {
        outcome.keys.sorted().map { name in
            let record = records[name]
            let masked = record.map { KeysCommand.mask($0.value) } ?? "····"
            let verdict: String
            switch outcome[name]! {
            case .set: verdict = "set (\(masked))"
            case .alreadySet: verdict = "already set (\(masked), \(record?.writtenBy.rawValue ?? "?"))"
            case .keptAccount: verdict = "kept: \(record?.writtenBy.displayName(in: home) ?? "an app")'s account key"
            }
            return "→ \(tilde(home.providersFile)): \(name) \(verdict)"
        }
    }

    /// "Sewn and Thread are", "Thread is", or nil: which servers run a build older than the
    /// one now installed.
    static func runningPreviousBuild(home: AIIHome) -> String? {
        let stale = [(LaunchSpec.Role.sewn, home.sewnRunRecord), (.thread, home.threadRunRecord)].compactMap { role, file -> String? in
            guard let record = RunRecord.load(file), ProcessProbe.isRunning(record.process),
                  ManagedServer.isStale(recordedBinary: record.binary, processStart: record.process.processStart,
                                        contract: nil, wanted: home.serverBinary) else { return nil }
            return role.displayName
        }
        switch stale.count {
        case 0: return nil
        case 1: return "\(stale[0]) is"
        default: return "\(stale.joined(separator: " and ")) are"
        }
    }
}

/// Where `aii install` builds from.
enum CheckoutResolver {
    static func resolve(argument: String?, environment: [String: String] = ProcessInfo.processInfo.environment,
                        home: AIIHome = Stack.home,
                        binary: URL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath(),
                        workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                        verb: String = "install") throws -> URL {
        guard let url = try locate(argument: argument, environment: environment, home: home, binary: binary,
                                   workingDirectory: workingDirectory, verb: verb) else {
            throw AIIFailure.usage("no AII checkout found", hint: "pass one: aii \(verb) ~/Documents/rao/repositories/AII")
        }
        return url
    }

    /// The checkout, or nil when none of the candidates is one. A named argument that isn't
    /// a checkout is still a usage error.
    static func locate(argument: String?, environment: [String: String] = ProcessInfo.processInfo.environment,
                       home: AIIHome = Stack.home,
                       binary: URL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath(),
                       workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                       verb: String = "install") throws -> URL? {
        var candidates: [(URL, String)] = []
        if let argument {
            let url = URL(fileURLWithPath: AIIHome.expandTilde(argument), relativeTo: workingDirectory).standardizedFileURL
            guard AIICheckout.isCheckout(url) else {
                throw AIIFailure.usage("\(argument) is not an AII checkout", hint: "it needs Package.swift and Scripts/build-servers.sh")
            }
            return url
        }
        if let named = environment["AII_CHECKOUT"], !named.isEmpty {
            candidates.append((URL(fileURLWithPath: AIIHome.expandTilde(named)), "AII_CHECKOUT"))
        }
        if let record = AIIInstallRecord.load(home: home), record.source == .local, let path = record.checkout?.path {
            candidates.append((URL(fileURLWithPath: path), "the installed build"))
        }
        if let record = CLIRecord.load(home: home) {
            candidates.append((URL(fileURLWithPath: record.checkout), tilde(home.cliRecord)))
        }
        if let found = enclosingCheckout(of: binary.deletingLastPathComponent()) { candidates.append((found, "this aii's folder")) }
        if let found = enclosingCheckout(of: workingDirectory) { candidates.append((found, "the current folder")) }
        for (url, origin) in candidates where AIICheckout.isCheckout(url) {
            note("\(verb): checkout \(tilde(url)) (from \(origin))")
            return url
        }
        return nil
    }

    /// The nearest folder at or above `start` holding AII's own Package.swift.
    static func enclosingCheckout(of start: URL) -> URL? {
        var folder = start.standardizedFileURL
        while folder.path != "/" {
            let manifest = folder.appendingPathComponent("Package.swift")
            if let text = try? String(contentsOf: manifest, encoding: .utf8), text.contains("name: \"AII\""),
               AIICheckout.isCheckout(folder) {
                return folder
            }
            folder = folder.deletingLastPathComponent()
        }
        return nil
    }
}
