//
//  ChatGenerationParameters.swift
//  Sewn
//
//  Created by Ritesh Pakala on 10/28/25.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation

struct ChatGenerationParameters {
    let maxTokens: Int
    let temperature: Float
    let topP: Float
    let repetitionPenalty: Float
    let repetitionContextSize: Int
    let kvBits: Int?
    let kvGroupSize: Int
    let quantizedKVStart: Int
}
