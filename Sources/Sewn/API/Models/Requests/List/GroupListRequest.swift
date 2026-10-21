//
//  GroupListRequest.swift
//  Sewn
//
//  Created by Ritesh Pakala on 12/10/25.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation


struct GroupListRequest: Codable {
    let sewn: SewnRequest
    let limit: Int?
    let afterId: String?

    enum CodingKeys: String, CodingKey {
        case sewn
        case limit
        case afterId = "after_id"
    }
}
