//
//  Options.swift
//  AIICLI
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: What every command shares: the home (AII_HOME, else ~/.rao) and the stack's
//        supervisor, installer, leases and client, all acting as the stack identity (`aii`);
//        the run wrapper that prints failures; notes on stderr; paths as people read them.
//  PIN:  The command is the stack, never an app: it holds a pinned lease when it starts the
//        servers and none when it only looks. AII_HOME is the one override; there is no
//        --home. Results go to stdout, progress to stderr, so `aii status --json | jq` works.
//

import AII
import ArgumentParser
import Foundation

enum Stack {
    static var home: AIIHome { AIIHome.resolved() }
    /// Starting and restarting run what is installed under the same rule an app built the
    /// same way would: a release command checks a bundled build's signature.
    static func supervisor(hold: AIISupervisor.Hold) -> AIISupervisor {
        AIISupervisor(identity: .stack, home: home, policy: .standard, hold: hold)
    }
    static var installer: AIIInstaller { AIIInstaller(home: home) }
    static var leases: AIILeases { AIILeases(home: home) }
    static func client() -> AIIClient { AIIClient(identity: .stack, home: home) }
}

/// Progress and chatter, on stderr: stdout stays the result.
func note(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}

/// A command's body: a failure is printed as `aii: …` with its hint, and the process exits
/// with its code.
func guarded(_ body: () async throws -> Void) async {
    do {
        try await body()
    } catch let exit as ExitCode {
        Foundation.exit(exit.rawValue)
    } catch {
        let failure = AIIFailure.from(error)
        FileHandle.standardError.write(Data((failure.description + "\n").utf8))
        Foundation.exit(failure.code.rawValue)
    }
}

extension LaunchSpec.Role: ExpressibleByArgument {}
extension AIIModels.Role: ExpressibleByArgument {}

/// A path as people read it: the home directory as `~`.
func tilde(_ path: String) -> String {
    let home = PrivateFile.path(AIIHome.userHomeDirectory)
    if path == home { return "~" }
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

func tilde(_ url: URL) -> String { tilde(PrivateFile.path(url)) }

/// A line as people read it: the home directory as `~` wherever a path in it starts there.
func tildeInText(_ text: String) -> String {
    text.replacingOccurrences(of: PrivateFile.path(AIIHome.userHomeDirectory) + "/", with: "~/")
}

enum Stamp {
    static func minute(_ date: Date) -> String { format(date, "yyyy-MM-dd HH:mm") }
    static func time(_ date: Date) -> String { format(date, "HH:mm") }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

/// The checkout the installed aii was built from: ~/.rao/bin/aii.json, written by
/// Scripts/install-cli.sh.
struct CLIRecord: Codable, Equatable {
    var checkout: String
    var commit: String
    var configuration: String
    var installedAt: Date

    static func load(home: AIIHome) -> CLIRecord? {
        guard let data = FileManager.default.contents(atPath: PrivateFile.path(home.cliRecord)) else { return nil }
        return try? AIIHome.decoder.decode(CLIRecord.self, from: data)
    }
}
