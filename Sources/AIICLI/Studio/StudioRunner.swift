//
//  StudioRunner.swift
//  AIICLI
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Opening the studio: the terminal, the app loop with StudioApp's functions, the
//        backend, and the first reads.
//  PIN:  The screen draws on a copy of the terminal's output while stdout and stderr go to a
//        log (the temporary folder's aii-studio.log), so nothing a library prints scribbles
//        over it. The terminal is restored on every way out; two Ctrl-Cs exit with 130.
//

import AII
import ArgumentParser
import Darwin
import Foundation

@MainActor
final class BackendBox {
    var backend: StudioBackend?
}

/// Points stdout and stderr at a file for as long as the studio is up.
final class StreamRedirect {
    private var saved: [(Int32, Int32)] = []

    init(to url: URL) throws {
        let fd = open(PrivateFile.path(url), O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { throw AIIFailure.internalError("can't open \(tilde(url)) for the studio's log") }
        fflush(stdout)
        fflush(stderr)
        for target in [STDOUT_FILENO, STDERR_FILENO] {
            saved.append((target, dup(target)))
            dup2(fd, target)
        }
        close(fd)
    }

    func restore() {
        fflush(stdout)
        fflush(stderr)
        for (target, copy) in saved {
            dup2(copy, target)
            close(copy)
        }
        saved.removeAll()
    }
}

enum StudioRunner {
    static var log: URL { FileManager.default.temporaryDirectory.appendingPathComponent("aii-studio.log") }

    @MainActor
    static func run() async throws {
        let tty = dup(STDOUT_FILENO)
        guard tty >= 0 else { throw AIIFailure.internalError("can't open the terminal") }
        defer { close(tty) }
        let terminal = Terminal(input: STDIN_FILENO, output: tty)
        let redirect = try StreamRedirect(to: log)
        defer { redirect.restore() }

        let box = BackendBox()
        let app = App<StudioState, StudioEvent>(
            display: terminal, initial: StudioState(),
            update: { state, event in
                for job in StudioApp.handle(event, state: &state) { box.backend?.submit(job) }
                if let code = state.quitCode { return .quit(code: code) }
                if state.redraw {
                    state.redraw = false
                    return .redraw
                }
                return .none
            },
            render: { state, frame in StudioApp.render(state, &frame) })
        let backend = StudioBackend(mailbox: app.mailbox, home: Stack.home)
        box.backend = backend
        for job in StudioApp.initialJobs { backend.submit(job) }
        let code = try await app.run()
        if code != 0 { throw ExitCode(code) }
    }
}
