//
//  SewnCore.Wearable.swift
//  Sewn
//
//  Created by Ritesh Pakala on 11/02/25.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation

/* Endgame: The World Computer. */

/// Wearable data that is placed into Sewn's database network.
/// Stored in embedding form, leading to contextual insights around
/// queries based on real-life environment variables.
extension SewnCore {
    struct Wearable: Codable {
        var url: URL
        var embedding: [Float]
        var kind: Kind
        
        enum Kind: String, Codable {
            case pin
            case ring
            case belt
            case bracelet
            case necklace
            case earring
            case glasses
        }
    }
}

/*
 Challenge:
 - Streaming encrypted embeddings into the right buckets continously. Nonstop.
 - Realtime knowledge and self-awareness. Without cameras.
 */
