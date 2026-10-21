//
//  CacheStatusResponse.swift
//  Sewn
//
//  Created by Ritesh Pakala on 10/26/25.
//  Copyright © 2026 Rao Studios LLC.
//  Based on: https://github.com/mzbac/swift-mlx-server
//


import Foundation

/// Response model for cache status
struct CacheStatusResponse: Codable {
    let enabled: Bool
    let entryCount: Int
    let currentSizeMB: Double
    let maxSizeMB: Int
    let ttlMinutes: Int
    let stats: CacheStatsResponse
}
