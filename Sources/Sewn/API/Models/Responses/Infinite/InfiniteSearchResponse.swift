//
//  InfiniteSearchResponse.swift
//  Sewn
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation


struct InfiniteSearchResponse: Codable {
    var object: String = "list"
    let groups: [SewnCore.Group]
    let total: Int

    enum CodingKeys: String, CodingKey {
        case object
        case groups
        case total
    }
}
