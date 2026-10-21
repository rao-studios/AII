//
//  SignInResponse.swift
//  Sewn
//
//  Created by Ritesh Pakala on 02/22/26.
//  Copyright © 2026 Rao Studios LLC.
//



struct SignInResponse: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Double
    let userId: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case userId = "user_id"
    }
}
