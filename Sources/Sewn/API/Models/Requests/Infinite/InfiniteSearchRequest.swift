//
//  InfiniteSearchRequest.swift
//  Sewn
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation


struct InfiniteSearchRequest: Codable {
    let query: String
    /// Maximum number of groups to return. Clamped to [1, 100]. Defaults to 20.
    let limit: Int?
    let sewn: SewnRequest

    enum CodingKeys: String, CodingKey {
        case query
        case limit
        case sewn
    }
}
