//
//  StackSecretMetadataTests.swift
//  SeamTests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  The pure checks behind the stack-secret interceptors: only the exact
//  secret matches, only this machine counts as loopback, and a server with
//  no secret gets no interceptor.
//

import GRPCCore
import XCTest
@testable import Seam

final class StackSecretMetadataTests: XCTestCase {

    func testPresentedReadsTheAgreedKey() {
        var metadata = Metadata()
        XCTAssertNil(StackSecretMetadata.presented(in: metadata))
        metadata.addString("s", forKey: "some-other-key")
        XCTAssertNil(StackSecretMetadata.presented(in: metadata))
        metadata.addString("s", forKey: StackSecretMetadata.key)
        XCTAssertEqual(StackSecretMetadata.presented(in: metadata), "s")
        XCTAssertEqual(StackSecretMetadata.key, "x-ambient-secret")
    }

    func testOnlyLoopbackPeersCount() {
        for peer in ["ipv4:127.0.0.1:1", "ipv6:[::1]:1", "ipv6:[::ffff:127.0.0.1]:1", "unix:/x", "in-process:7"] {
            XCTAssertTrue(StackSecretMetadata.isLoopbackPeer(peer), peer)
        }
        for peer in ["ipv4:10.0.0.4:1", "ipv6:[fe80::1]:1", "", "ipv4:127", "127.0.0.1:1", "ipv6:[::2]:1"] {
            XCTAssertFalse(StackSecretMetadata.isLoopbackPeer(peer), peer)
        }
    }

    func testForLocalModeInstallsAnInterceptorOnlyWithAResolver() {
        XCTAssertTrue(StackSecretServerInterceptor.forLocalMode(resolver: nil).isEmpty)
        let installed = StackSecretServerInterceptor.forLocalMode(resolver: { $0 == "s" ? "ambient" : nil })
        XCTAssertEqual(installed.count, 1)
        XCTAssertTrue(installed.first is StackSecretServerInterceptor)
    }
}
