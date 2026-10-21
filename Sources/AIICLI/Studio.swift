//
//  Studio.swift
//  AIICLI
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The studio's entry point (Studio/ holds the rest).
//

import Foundation

enum Studio {
    static func launch() async throws {
        try await StudioRunner.run()
    }
}
