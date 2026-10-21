//
//  Availability.swift
//  Thread
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//

import Seam
import Hummingbird

private struct AvailabilityRequest: Codable {
    let acceptingStorage: Bool

    enum CodingKeys: String, CodingKey {
        case acceptingStorage = "accepting_storage"
    }
}

private struct AvailabilityResponse: ResponseCodable {
    let accepted: Bool
}

func registerAvailabilityRoute(
    _ app: some RouterMethods<ThreadRequestContext>,
    registrationClient: MothershipRegistrationClient
) {
    app.post("/v1/availability") { request, context async throws -> AvailabilityResponse in
        let body = try await request.decode(as: AvailabilityRequest.self, context: context)
        await registrationClient.sendAvailabilityUpdate(acceptingStorage: body.acceptingStorage)
        return AvailabilityResponse(accepted: true)
    }
}
