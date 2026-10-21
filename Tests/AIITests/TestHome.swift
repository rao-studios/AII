//
//  TestHome.swift
//  AIITests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation
@testable import AII

/// A throwaway AII_HOME under the temp directory, removed on deinit.
final class TestHome {
    let home: AIIHome
    let url: URL

    init(file: StaticString = #file) {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rao-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("rao home", isDirectory: true)   // a space, on purpose
        home = AIIHome(root: url)
    }

    deinit {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func mode(_ url: URL) -> UInt16? { PrivateFile.ownerAndMode(url)?.mode }
}
