//
//  GroupModificationRequest.swift
//  Sewn
//
//  Created by Ritesh Pakala on 02/28/26.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation


struct GroupModificationRequest: Codable {
    let groupId: String
    let access: SewnRegistry.Access
    let label: String?
    let sewn: SewnRequest

    enum CodingKeys: String, CodingKey {
        case groupId = "group_id"
        case access
        case label
        case sewn
    }
}
