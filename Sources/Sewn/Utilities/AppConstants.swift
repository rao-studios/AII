//
//  AppConstants.swift
//  Sewn
//
//  Created by Ritesh Pakala on 10/26/25.
//  Copyright © 2026 Rao Studios LLC.
//  Based on: https://github.com/mzbac/swift-mlx-server
//

import Foundation

enum AppConstants {
    static let defaultHost = "127.0.0.1"
    static let defaultPort = 8_080
    static let sseDoneMessage = "data: [DONE]\n\n"
    static let sseEventHeader = "data: "
    static let sseEventSeparator = "\n\n"
}
