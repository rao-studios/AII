//
//  SummarizeRequest.swift
//  Sewn
//
//  Created by Ritesh Pakala on 11/01/25.
//  Copyright © 2026 Rao Studios LLC.
//



struct SummarizeRequest: Codable {
    let content: String
    let sewn: SewnRequest
}
