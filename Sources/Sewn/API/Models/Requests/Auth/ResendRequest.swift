//
//  ResendRequest.swift
//  Sewn
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//

/// `type`: `signup` (the confirmation code) or `recovery` (a reset code).
struct ResendRequest: Codable {
    let email: String
    let type: String
}
