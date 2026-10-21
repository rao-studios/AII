//
//  SewnProfile.swift
//  Sewn
//
//  Created by Ritesh Pakala on 03/24/26.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation
import Hummingbird

struct SewnProfile: Codable {
    let userId: String
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case displayName = "display_name"
    }
}