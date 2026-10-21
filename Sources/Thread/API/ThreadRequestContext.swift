//
//  ThreadRequestContext.swift
//  Thread
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//

import AII
import Hummingbird

/// A request context that remembers which stack identity the secret middleware
/// admitted, so routes can cut their work to that identity's lane.
protocol StackCallerContext: RequestContext {
    var callerIdentity: StackIdentity? { get set }
}

/// Custom request context for Thread.
///
/// - Overrides the 2 MB default `maxUploadSize` to 100 MB so that batch
///   embedding requests with large document payloads are accepted.
/// - Uses the standard `ApplicationRequestContextSource` initializer, making
///   it a drop-in for `BasicRequestContext` with no additional dependencies.
/// - Carries `callerIdentity`: the identity whose secret StackSecretMiddleware
///   matched (nil on an open Thread, where every request is unscoped).
struct ThreadRequestContext: StackCallerContext {
    var coreContext: CoreRequestContextStorage
    var callerIdentity: StackIdentity?

    init(source: ApplicationRequestContextSource) {
        self.coreContext = .init(source: source)
    }

    /// Allow up to 100 MB request bodies (needed for large batch embeddings).
    var maxUploadSize: Int { 100 * 1_024 * 1_024 }
}
