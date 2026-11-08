//
//  SearchRequest.swift
//  Sewn
//
//  Created by Ritesh Pakala on 11/01/25.
//  Copyright © 2026 Rao Studios LLC.
//



struct SearchRequest: Codable {
    let model: String?
    let query: String
    let train: Bool
    let sewn: SewnRequest
    /// Results across every node in scope (`top_k`); absent keeps the default of 3.
    let topK: Int?

    enum CodingKeys: String, CodingKey {
        case model, query, train, sewn
        case topK = "top_k"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        query = try container.decode(String.self, forKey: .query)
        train = try container.decodeIfPresent(Bool.self, forKey: .train) ?? false
        sewn = try container.decode(SewnRequest.self, forKey: .sewn)
        topK = try container.decodeIfPresent(Int.self, forKey: .topK)
    }
}
