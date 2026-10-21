//
//  ModelListResponse.swift
//  Sewn
//
//  Created by Ritesh Pakala on 10/26/25.
//  Copyright © 2026 Rao Studios LLC.
//  Based on: https://github.com/mzbac/swift-mlx-server
//

import Foundation


struct ModelListResponse: Codable {
    var object: String = "list"
    let data: [ModelInfo]
}

struct ModelInfo: Codable {
    let id: String
    var object: String = "model"
    let created = Int(Date().timeIntervalSince1970)
    let ownedBy: String = "user"

    enum CodingKeys: String, CodingKey {
        case id, object, created
        case ownedBy = "owned_by"
    }
}
