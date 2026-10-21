//
//  SupabaseProviderTests.swift
//  SewnTests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  An app indexing its own data needs no Supabase, so a missing project is a state: the auth
//  routes answer 503, the process never dies. Empty values (a copied .env.example) and a URL
//  with no scheme are "not configured" too.
//

import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import XCTest
@testable import Sewn

final class SupabaseProviderTests: XCTestCase {

    func testOnlyAFullPairConfiguresTheAccountsLayer() {
        XCTAssertNil(SupabaseProvider.configuration([:]))
        XCTAssertNil(SupabaseProvider.configuration(["SUPABASE_URL": "https://x.supabase.co"]), "the URL alone")
        XCTAssertNil(SupabaseProvider.configuration(["SUPABASE_URL": "", "SUPABASE_ANON_KEY": ""]), ".env.example ships KEY= lines")
        XCTAssertNil(SupabaseProvider.configuration(["SUPABASE_URL": "https://x.supabase.co", "SUPABASE_ANON_KEY": " "]))
        XCTAssertNil(SupabaseProvider.configuration(["SUPABASE_URL": "not a url", "SUPABASE_ANON_KEY": "k"]), "no scheme, no host")
        XCTAssertNil(SupabaseProvider.configuration(["SUPABASE_URL": "/auth", "SUPABASE_ANON_KEY": "k"]), "a path passed the old guard")
        let full = SupabaseProvider.configuration(["SUPABASE_URL": "https://xyz.supabase.co ", "SUPABASE_ANON_KEY": "anon"])
        XCTAssertEqual(full?.url, URL(string: "https://xyz.supabase.co"))
        XCTAssertEqual(full?.anonKey, "anon")
    }

    func testTheAnswerWithoutAProjectIs503() {
        XCTAssertEqual(SupabaseProvider.notConfigured.status, .serviceUnavailable)
        XCTAssertEqual(SupabaseProvider.notConfigured.body, "Auth service not configured")
    }

    func testTheAuthRoutesAnswer503InsteadOfCrashing() async throws {
        try XCTSkipIf(SupabaseProvider.configuration() != nil, "Supabase is configured in this shell")
        XCTAssertThrowsError(try SupabaseProvider.shared) { error in
            XCTAssertEqual((error as? Hummingbird.HTTPError)?.status, .serviceUnavailable)
        }
        XCTAssertThrowsError(try SupabaseProvider.makeClient())

        let router = Router(context: SewnRequestContext.self)
        registerAuthSignInRoute(router)
        registerAuthRefreshRoute(router)
        registerAuthResetPasswordRoute(router)
        let calls: [(String, String)] = [
            ("/v1/auth/sign-in", #"{"email":"a@b.c","password":"x"}"#),
            ("/v1/auth/refresh", #"{"refresh_token":"r"}"#),
            ("/v1/auth/reset-password", #"{"email":"a@b.c"}"#),
        ]
        try await Application(router: router).test(.router) { client in
            for (uri, body) in calls {
                try await client.execute(uri: uri, method: .post, headers: [.contentType: "application/json"],
                                         body: ByteBuffer(string: body)) { response in
                    XCTAssertEqual(response.status, .serviceUnavailable, uri)
                    XCTAssertTrue(String(buffer: response.body).contains("Auth service not configured"), uri)
                }
            }
        }
    }
}
