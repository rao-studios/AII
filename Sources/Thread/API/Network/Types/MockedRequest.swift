//
//  MockedRequest.swift
//  Thread
//
//  Created by Ritesh Pakala on 12/21/25.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation

protocol AnyMockedRequest {
    
    var rawMockedResponse : Any { get }
    
}

protocol MockedRequest : NetworkRequest {
    var mockedResponse : TransformedResponse { get }
}

extension MockedRequest {
    
    var rawMockedResponse : Any {
        mockedResponse
    }
    
}
