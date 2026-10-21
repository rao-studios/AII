//
//  GroupMetadataRequest.swift
//  Sewn
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation


struct GroupMetadataRequest: Codable {
    let groupId: String
    let label: String?
    let metadata: SewnCore.Group.Metadata
    let sewn: SewnRequest

    enum CodingKeys: String, CodingKey {
        case groupId = "group_id"
        case label
        case metadata
        case sewn
    }
}
