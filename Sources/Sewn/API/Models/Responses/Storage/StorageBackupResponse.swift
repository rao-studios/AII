//
//  StorageBackupResponse.swift
//  Sewn
//
//  Created by Ritesh Pakala on 02/27/26.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation


struct StorageBackupResponse: Codable {
    var object: String = "storage.backup"
    let ownerId: String
    let backedUpCount: Int
    let failedCount: Int
    let backedUpAt: Date

    enum CodingKeys: String, CodingKey {
        case object
        case ownerId      = "owner_id"
        case backedUpCount = "backed_up_count"
        case failedCount  = "failed_count"
        case backedUpAt   = "backed_up_at"
    }
}
