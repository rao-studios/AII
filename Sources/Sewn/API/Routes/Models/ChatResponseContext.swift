//
//  ChatResponseContext.swift
//  Sewn
//
//  Created by Ritesh Pakala on 10/28/25.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation

struct ChatResponseContext {
    let loadedModelName: String
    let stopIdSequences: [[Int]]
    // let detokenizer: NaiveStreamingDetokenizer
    let estimatedPromptTokens: Int
}
