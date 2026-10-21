//
//  ChatMessageResponseData.swift
//  Sewn
//
//  Created by Ritesh Pakala on 10/26/25.
//  Copyright © 2026 Rao Studios LLC.
//  Based on: https://github.com/mzbac/swift-mlx-server
//


import Foundation

struct ChatMessageResponseData: Codable {
    let role: String
    let content: String?
    let refusal: String? = nil

    enum CodingKeys: String, CodingKey {
        case role, content, refusal
    }

    init(role: String, content: String?) {
        self.role = role
        self.content = content
    }
}
