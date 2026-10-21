//
//  CompletionsResponse.swift
//  Sewn
//
//  Created by Ritesh Pakala on 10/26/25.
//  Copyright © 2026 Rao Studios LLC.
//  Based on: https://github.com/mzbac/swift-mlx-server
//


import Foundation

struct CompletionResponse: Codable {
    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [CompletionChoice]
    let usage: CompletionUsage

    init(id: String = "cmpl-\(UUID().uuidString)", object: String = "text_completion", model: String, choices: [CompletionChoice], usage: CompletionUsage) {
        self.id = id
        self.object = object
        self.created = Int(Date().timeIntervalSince1970)
        self.model = model
        self.choices = choices
        self.usage = usage
    }

     enum CodingKeys: String, CodingKey {
        case id, object, created, model, choices, usage
    }
}
