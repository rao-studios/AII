//
//  GroupRemoveRequest.swift
//  Sewn
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation


struct GroupRemoveRequest: Codable {
    let groupId: String
    let sewn: SewnRequest

    enum CodingKeys: String, CodingKey {
        case groupId = "group_id"
        case sewn
    }
}
