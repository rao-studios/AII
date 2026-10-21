//
//  LockedValue.swift
//  Thread
//
//  Created by Ritesh Pakala on 03/19/26.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation

/// A cross-platform, thread-safe wrapper that protects a value with an `NSLock`.
///
/// API mirrors `OSAllocatedUnfairLock` so call sites are identical — only the
/// declaration changes. `NSLock` is available on both Apple platforms and Linux
/// via swift-corelibs-foundation.
final class LockedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) {
        self.value = value
    }

    @discardableResult
    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
