//
//  NetworkService.swift
//  Sewn
//
//  Created by Ritesh Pakala on 12/21/25.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation
import Logging

/// Actor-based network service for making HTTP requests
actor NetworkService {
    var configuration: Configuration
    
    let logger: Logger
    
    init(logger: Logger, base endpoint: BaseEndpoint = .mistral) {
        self.logger = logger
        self.configuration = Configuration(base: endpoint)
    }
}

