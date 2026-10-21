//
//  Logs.swift
//  AIICLI
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: `aii logs [sewn|thread] [-f] [-n N]`: the last lines of a server's log, or both,
//        and follow them.
//  PIN:  tail(1) does it: two files get its own headers, and Ctrl-C reaches it directly.
//

import AII
import ArgumentParser
import Foundation

struct LogsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "The last lines of a server's log, or both, and follow them.")

    @Argument(help: "sewn or thread. Default: both.")
    var role: LaunchSpec.Role?

    @Flag(name: [.short, .long], help: "Keep printing as they write.")
    var follow = false

    @Option(name: .short, help: "How many lines.")
    var n = 50

    func run() async throws {
        await guarded {
            let home = Stack.home
            let files: [URL]
            switch role {
            case .sewn: files = [home.sewnLogFile]
            case .thread: files = [home.threadLogFile]
            case nil: files = [home.sewnLogFile, home.threadLogFile]
            }
            let present = files.filter { PrivateFile.exists($0) }
            guard !present.isEmpty else {
                throw AIIFailure.missing("no log yet in \(tilde(home.aiiRunDirectory))", hint: "aii start")
            }
            let arguments = ["tail", "-n", String(max(n, 1))] + (follow ? ["-f"] : []) + present.map(PrivateFile.path)
            let argv = arguments.map { strdup($0) } + [nil]
            execv("/usr/bin/tail", argv)
            throw AIIFailure.internalError("couldn't run tail: \(String(cString: strerror(errno)))")
        }
    }
}
