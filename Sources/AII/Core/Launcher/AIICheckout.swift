//
//  AIICheckout.swift
//  AII
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: What a local build is named after: the AII checkout it came from, and that
//        checkout's commit.
//  IN:   AIIInstallPayload.checkout (the commit for install.json and `aii status`), and
//        the aii command (whether a folder is an AII checkout).
//  OUT:  `commit(of:)`, 12 hex characters with `-dirty` when the tree has changes, or
//        `unknown`; `isCheckout(_:)`.
//  PIN:  git is asked, never parsed from .git by hand; a folder git can't read is
//        `unknown`, not an error, so a tarball of the repo still installs.
//

#if os(macOS)
import Foundation

public enum AIICheckout {

    /// The checkout's commit: 12 hex characters, `-dirty` appended when its tree has
    /// uncommitted changes; `unknown` when git can't say.
    public static func commit(of root: URL) -> String {
        guard let head = git(["rev-parse", "--short=12", "HEAD"], in: root), !head.isEmpty else { return "unknown" }
        let changes = git(["status", "--porcelain"], in: root) ?? ""
        return changes.isEmpty ? head : head + "-dirty"
    }

    /// Whether `root` is an AII checkout: a package manifest and the server build script.
    public static func isCheckout(_ root: URL) -> Bool {
        let manager = FileManager.default
        return manager.fileExists(atPath: PrivateFile.path(root.appendingPathComponent("Package.swift")))
            && manager.fileExists(atPath: PrivateFile.path(root.appendingPathComponent("Scripts/build-servers.sh")))
    }

    private static func git(_ arguments: [String], in root: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", PrivateFile.path(root)] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
