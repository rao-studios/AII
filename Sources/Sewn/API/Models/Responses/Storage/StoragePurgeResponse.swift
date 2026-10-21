//
//  StoragePurgeResponse.swift
//  Sewn
//
//  Created by Ritesh Pakala on 02/27/26.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation


struct StoragePurgeResponse: Codable {
    var object: String = "storage.purge"
    let ownerId: String
    let purgedCount: Int

    enum CodingKeys: String, CodingKey {
        case object
        case ownerId     = "owner_id"
        case purgedCount = "purged_count"
    }
}
