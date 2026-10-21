//
//  SignOutRequest.swift
//  Sewn
//
//  Created by Ritesh Pakala on 02/22/26.
//  Copyright © 2026 Rao Studios LLC.
//



/// The access token is read from the `Authorization: Bearer` header.
/// The refresh token is required so the server can set the full session
/// before calling Supabase's sign-out endpoint.
/// `scope`: `global` (all devices), `local` (this session only),
/// `others` (all other sessions). Defaults to `global`.
struct SignOutRequest: Codable {
    let refreshToken: String
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
        case scope
    }
}
