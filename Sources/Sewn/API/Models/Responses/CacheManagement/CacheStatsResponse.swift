//
//  CacheStatsResponse.swift
//  Sewn
//
//  Created by Ritesh Pakala on 10/26/25.
//  Copyright © 2026 Rao Studios LLC.
//  Based on: https://github.com/mzbac/swift-mlx-server
//


import Foundation

/// Response model for cache statistics
struct CacheStatsResponse: Codable {
    let hits: Int
    let misses: Int
    let evictions: Int
    let hitRate: Double
    let totalTokensReused: Int
    let totalTokensProcessed: Int
    let averageTokensReused: Double
}
