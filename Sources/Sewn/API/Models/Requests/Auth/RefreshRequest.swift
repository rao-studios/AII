//
//  RefreshRequest.swift
//  Sewn
//
//  Created by Ritesh Pakala on 02/22/26.
//  Copyright © 2026 Rao Studios LLC.
//



struct RefreshRequest: Codable {
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
    }
}
