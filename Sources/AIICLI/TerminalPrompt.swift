//
//  TerminalPrompt.swift
//  AIICLI
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Asking in a plain terminal: a secret with echo off, a line in the clear.
//  OUT:  `Prompt.readSecret`, `Prompt.readLine`: the trimmed answer, or nil when there is no
//        terminal to ask on — so a caller skips instead of blocking a script.
//  PIN:  `readpassphrase(3)` with RPP_REQUIRE_TTY writes the label to /dev/tty and fails
//        cleanly without one, so no termios juggling; the buffer is wiped after use. The
//        reader is injectable: tests script the answers, nothing reads a real terminal.
//

import Darwin
import Foundation

enum TerminalPrompt {
    struct Reader: Sendable {
        /// The label in, the answer out; nil when there is nobody to ask.
        var secret: @Sendable (String) -> String?
        var line: @Sendable (String) -> String?

        static let terminal = Reader(secret: TerminalPrompt.terminalSecret, line: TerminalPrompt.terminalLine)

        /// Answers in order; nil answers stand for "no terminal".
        static func scripted(_ answers: [String?]) -> Reader {
            let queue = Answers(answers)
            return Reader(secret: { _ in queue.next() }, line: { _ in queue.next() })
        }
    }

    /// A secret, echo off. Nil without a terminal.
    static func readSecret(_ label: String, reader: Reader = .terminal) -> String? {
        reader.secret(label).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// A line in the clear. Nil without a terminal.
    static func readLine(_ label: String, reader: Reader = .terminal) -> String? {
        reader.line(label).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static let terminalSecret: @Sendable (String) -> String? = { label in
        let size = 1024
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: size)
        defer {
            _ = memset_s(buffer, size, 0, size)
            buffer.deallocate()
        }
        guard readpassphrase(label, buffer, size, RPP_ECHO_OFF | RPP_REQUIRE_TTY) != nil else { return nil }
        return String(cString: buffer)
    }

    private static let terminalLine: @Sendable (String) -> String? = { label in
        guard Terminal.isInteractive else { return nil }
        FileHandle.standardError.write(Data(label.utf8))
        return Swift.readLine(strippingNewline: true)
    }

    private final class Answers: @unchecked Sendable {
        private var answers: [String?]
        private let lock = NSLock()
        init(_ answers: [String?]) { self.answers = answers }
        func next() -> String? {
            lock.withLock { answers.isEmpty ? nil : answers.removeFirst() }
        }
    }
}
