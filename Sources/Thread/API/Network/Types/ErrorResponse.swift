//
//  ErrorResponse.swift
//  Thread
//
//  Created by Ritesh Pakala on 12/21/25.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation

struct ErrorResponse: Codable {
    var correlationId: String
    var statusCode: Int
    var message: String
}
