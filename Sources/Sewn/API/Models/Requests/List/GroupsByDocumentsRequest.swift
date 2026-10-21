//
//  GroupsByDocumentsRequest.swift
//  Sewn
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation


struct GroupsByDocumentsRequest: Codable {
    let sewn: SewnRequest
    let documentIds: [DocumentID]

    enum CodingKeys: String, CodingKey {
        case sewn
        case documentIds = "document_ids"
    }
}
