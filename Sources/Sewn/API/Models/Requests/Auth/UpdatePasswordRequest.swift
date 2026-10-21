//
//  UpdatePasswordRequest.swift
//  Sewn
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//

/// The signed-in user's new password; the Bearer header says whose.
struct UpdatePasswordRequest: Codable {
    let password: String
}
