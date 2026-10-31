//
//  ChatCompletionDelta.swift
//  Sewn
//
//  Created by Ritesh Pakala on 10/26/25.
//  Copyright © 2026 Rao Studios LLC.
//  Based on: https://github.com/mzbac/swift-mlx-server
//


import Foundation

struct ChatCompletionDelta: Codable {
    var role: String?
    var content: String?
    /// A reasoning model's thinking, apart from `content`: it streams before the answer
    /// and is never part of the reply. Absent for models that don't reason.
    var reasoning: String? = nil
}

struct ChatCompletionChoiceDelta: Codable {
    let index: Int
    let delta: ChatCompletionDelta
    let logprobs: String? = nil
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case index, delta, logprobs
        case finishReason = "finish_reason"
    }
}
