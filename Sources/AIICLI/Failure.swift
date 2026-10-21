//
//  Failure.swift
//  AIICLI
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: One failure type the command prints and maps to sysexits, so scripts can branch on
//        the code; and every library error, in the command's words.
//  PIN:  `aii: message` on stderr with the hint indented under it: lowercase, no trailing
//        period, the next command when there is one. Nothing printed is ever a secret.
//

import AII
import Foundation

/// The command's exit codes (sysexits), as Docs/AII/CLI.md lists them.
enum Exit: Int32 {
    case ok = 0
    /// `aii doctor` found a failing check.
    case doctor = 1
    case usage = 64
    case data = 65
    case missing = 66
    case unavailable = 69
    case internalError = 70
    /// Try again: an app is running, or holds the stack.
    case temporary = 75
    case configuration = 78
    case interrupted = 130
}

struct AIIFailure: Error, Equatable, CustomStringConvertible {
    var message: String
    var hint: String?
    var code: Exit

    static func usage(_ message: String, hint: String? = nil) -> AIIFailure { .init(message: message, hint: hint, code: .usage) }
    static func data(_ message: String, hint: String? = nil) -> AIIFailure { .init(message: message, hint: hint, code: .data) }
    static func missing(_ message: String, hint: String? = nil) -> AIIFailure { .init(message: message, hint: hint, code: .missing) }
    static func unavailable(_ message: String, hint: String? = nil) -> AIIFailure { .init(message: message, hint: hint, code: .unavailable) }
    static func internalError(_ message: String, hint: String? = nil) -> AIIFailure { .init(message: message, hint: hint, code: .internalError) }
    static func temporary(_ message: String, hint: String? = nil) -> AIIFailure { .init(message: message, hint: hint, code: .temporary) }
    static func configuration(_ message: String, hint: String? = nil) -> AIIFailure { .init(message: message, hint: hint, code: .configuration) }

    var description: String { "aii: \(message)" + (hint.map { "\n  \($0)" } ?? "") }

    /// Any error, in the command's words.
    static func from(_ error: Error) -> AIIFailure {
        if let failure = error as? AIIFailure { return failure }
        let text = Self.sentence(String(describing: error))
        switch error {
        case let install as AIIInstallError:
            switch install {
            case .notInstalled: return .missing(text, hint: "aii install, or launch a Rao app")
            case .notBuilt: return .missing(text, hint: "drop --no-build, or run Scripts/build-servers.sh")
            case .modified: return .data(text, hint: "put your build back: aii install")
            case .copyFailed: return .internalError(text)
            case .untrustedRecord: return .configuration(text, hint: "aii install writes it again")
            case .localBuildBehind: return .configuration(text, hint: "aii update")
            }
        case is SignatureError:
            return .data(text, hint: "a release app runs only Rao's signed build, or your own: aii install")
        case let home as AIIHomeError:
            switch home {
            case .invalidAppName, .reservedName: return .usage(text)
            default: return .configuration(text)
            }
        case let client as AIIClientError:
            switch client {
            case .unauthorized: return .configuration(text, hint: "aii doctor")
            case .transport: return .unavailable(text, hint: "is the stack up? aii start")
            case .http(let status, _) where status >= 500: return .unavailable(text, hint: "aii logs sewn")
            case .http: return .data(text)
            case .notLoopback, .decoding: return .internalError(text)
            }
        case is ManagedServerError:
            return .unavailable(text, hint: "aii logs")
        case is PrivateFileError:
            return .configuration(text, hint: "aii doctor")
        case is AIIEnvironmentFile.WriteError:
            return .usage(text)
        case is ProviderKeyStoreError:
            return .data(text, hint: "aii keys set mistral writes it again")
        default:
            return .internalError(text)
        }
    }

    /// A library message as the command prints one: first letter lowercase (unless it
    /// starts an acronym), no trailing period.
    static func sentence(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(".") { text.removeLast() }
        guard let first = text.first, first.isUppercase else { return text }
        let second = text.dropFirst().first
        if let second, second.isUppercase { return text }
        return first.lowercased() + text.dropFirst()
    }
}
