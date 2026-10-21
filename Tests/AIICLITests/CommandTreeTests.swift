//
//  CommandTreeTests.swift
//  AIICLITests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  Every command has a name, a one-line abstract and help that names it; every documented
//  invocation parses; and bare `aii` opens the studio only in a terminal.
//

import ArgumentParser
import XCTest
@testable import AIICLI

final class CommandTreeTests: XCTestCase {

    private func walk(_ command: ParsableCommand.Type, path: [String] = []) -> [(ParsableCommand.Type, [String])] {
        let here = path + [command.configuration.commandName ?? ""]
        return [(command, here)] + command.configuration.subcommands.flatMap { walk($0, path: here) }
    }

    func testEveryCommandIsNamedAndSaysWhatItDoes() {
        XCTAssertEqual(AIICommand.configuration.commandName, "aii")
        let commands = walk(AIICommand.self)
        XCTAssertGreaterThanOrEqual(commands.count, 25)
        for (command, path) in commands {
            let help = AIICommand.helpMessage(for: command)
            XCTAssertTrue(help.contains("USAGE: \(path.joined(separator: " "))"), "\(path): \(help.prefix(120))")
            XCTAssertGreaterThan(command.configuration.abstract.count, 10, "\(path)")
            XCTAssertTrue(command.configuration.abstract.hasSuffix("."), "\(path): an abstract is a sentence")
        }
    }

    func testTheDocumentedInvocationsParse() throws {
        let invocations: [[String]] = [
            ["status"], ["status", "--json"], ["doctor"],
            ["setup"], ["setup", "--no-start", "--no-models", "--no-prompt"], ["setup", "/x", "--debug", "--no-build", "--no-install"],
            ["setup", "--mistral-key-stdin", "--supabase-url", "https://x.supabase.co", "--supabase-anon-key", "k"],
            ["keys"], ["keys", "list"], ["keys", "set", "mistral"], ["keys", "set", "tinker", "--stdin", "--force"],
            ["keys", "remove", "mistral", "--yes"], ["keys", "supabase", "--url", "https://x.supabase.co", "--anon-key", "k"],
            ["keys", "supabase", "--remove", "--yes"],
            ["install"], ["install", "/x", "--debug", "--no-build"], ["update"], ["uninstall", "--yes"],
            ["start"], ["stop"], ["stop", "--force"], ["restart"], ["restart", "thread"], ["restart", "sewn"],
            ["logs"], ["logs", "sewn", "-f", "-n", "20"],
            ["lanes"], ["lanes", "list"], ["lanes", "add", "notes", "--display", "Notes"], ["lanes", "remove", "notes", "--yes"],
            ["models"], ["models", "pull", "coding"], ["models", "remove", "coding", "--yes"],
            ["reset"], ["reset", "--yes"],
        ]
        for arguments in invocations {
            XCTAssertNoThrow(try AIICommand.parseAsRoot(arguments), "\(arguments)")
        }
        XCTAssertTrue(try AIICommand.parseAsRoot(["lanes"]) is LanesCommand.List)
        XCTAssertTrue(try AIICommand.parseAsRoot(["models"]) is ModelsCommand.List)
        XCTAssertTrue(try AIICommand.parseAsRoot(["keys"]) is KeysCommand.List)
        XCTAssertThrowsError(try AIICommand.parseAsRoot(["restart", "x"]))
        XCTAssertThrowsError(try AIICommand.parseAsRoot(["models", "pull", "nope"]))
        XCTAssertThrowsError(try AIICommand.parseAsRoot(["keys", "set", "openai"]), "only providers the stack knows")
    }

    func testBareAiiOpensTheStudioOnlyInATerminal() {
        XCTAssertTrue(AIICommand.opensStudio(environment: ["TERM": "xterm-256color"], interactive: true))
        XCTAssertFalse(AIICommand.opensStudio(environment: ["TERM": "xterm-256color"], interactive: false), "piped: status")
        XCTAssertFalse(AIICommand.opensStudio(environment: ["TERM": "dumb"], interactive: true))
        XCTAssertFalse(AIICommand.opensStudio(environment: ["AII_NO_UI": "1"], interactive: true))
    }
}
