//
//  Database.User.swift
//  Thread
//
//  Created by Ritesh Pakala on 12/15/25.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation

extension Database {
    struct User: Codable {
        var groups: [Database.Group]
    }
}
