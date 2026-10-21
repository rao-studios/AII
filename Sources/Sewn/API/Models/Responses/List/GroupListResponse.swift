//
//  GroupListResponse.swift
//  Sewn
//
//  Created by Ritesh Pakala on 12/10/25.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation


struct GroupListResponse: Codable {
    var object: String = "list"
    let groups: [SewnCore.Group]
    let access: [GroupID: SewnRegistry.Access]
    var hasMore: Bool = false
    var nextAfterId: String? = nil

    enum CodingKeys: String, CodingKey {
        case object, groups, access
        case hasMore     = "has_more"
        case nextAfterId = "next_after_id"
    }
}
