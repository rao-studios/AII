//
//  ChatGenerationContext.swift
//  Sewn
//
//  Created by Ritesh Pakala on 10/28/25.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation
import Logging

struct ChatGenerationContext {
    // let modelContainer: ModelContainer
    // let tokenizer: Tokenizer
    let eosTokenId: Int
    let userInput: UserInput
    let logger: Logger
}
