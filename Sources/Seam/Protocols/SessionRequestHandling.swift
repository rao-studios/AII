//
//  SessionRequestHandling.swift
//  Seam
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//

/// Handles fan-out requests arriving on the bidirectional session stream and
/// returns the correlated response message (nil if the payload is unsupported).
public protocol SessionRequestHandling: Sendable {
    func handle(_ msg: Thread_V1_ThreadSessionMessage) async -> Thread_V1_ThreadSessionMessage?
}
