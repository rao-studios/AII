//
//  VerifyRequest.swift
//  Sewn
//
//  Created by Ritesh Pakala on 02/22/26.
//  Copyright © 2026 Rao Studios LLC.
//



/// Verifies an email OTP sent by Supabase.
/// - `type`: one of `signup`, `invite`, `magiclink`, `recovery`,
///   `email_change`, `email`
struct VerifyRequest: Codable {
    let email: String
    let token: String
    let type: String

    enum CodingKeys: String, CodingKey {
        case email
        case token
        case type
    }
}
