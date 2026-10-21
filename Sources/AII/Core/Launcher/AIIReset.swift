//
//  AIIReset.swift
//  AII
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Bringing a home back to a fresh layout-1 state: the installed build, its
//        record, the run records, the leases and layout.json go.
//  IN:   `aii reset`, after it has stopped the servers.
//  OUT:  `plan(home:)`, the paths that would go, and `apply(_:)`.
//  PIN:  Keeps secrets/, keys/ (the device key is the lanes' and Veil's corpus key),
//        aii/sewn/db (Sewn's wallets and Sinatra state), aii/thread/db (the index),
//        aii/aii.env, aii/lanes.json, apps/, models/ and bin/ (the aii command). The
//        first app start, or `aii install`, puts a build back.
//

import Foundation

public enum AIIReset {

    /// What a reset of `home` removes: each path that exists now.
    public static func plan(home: AIIHome) -> [URL] {
        [home.aiiBinDirectory, home.aiiInstallRecord, home.aiiRunDirectory, home.aiiLeasesDirectory, home.layoutFile]
            .filter { PrivateFile.exists($0) }
    }

    /// Removes each path in `paths`.
    public static func apply(_ paths: [URL]) throws {
        for path in paths where PrivateFile.exists(path) {
            try FileManager.default.removeItem(at: path)
        }
    }
}
