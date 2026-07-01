//
//  CodexAuthTests.swift
//  zoroTests
//

import XCTest
@testable import zoro

final class CodexAuthTests: XCTestCase {
    func testSanitizedErrorDetailRedactsJWT() {
        let token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsRMSU"
        let input = "upstream failed: \(token)"
        let sanitized = CodexAuthSupport.sanitizedErrorDetail(input)
        XCTAssertFalse(sanitized.contains("eyJ"))
        XCTAssertTrue(sanitized.contains("[redacted-token]"))
    }

    func testSanitizedErrorDetailTruncatesLongMessages() {
        let long = String(repeating: "a", count: 400)
        let sanitized = CodexAuthSupport.sanitizedErrorDetail(long)
        XCTAssertLessThanOrEqual(sanitized.count, 281)
        XCTAssertTrue(sanitized.hasSuffix("…"))
    }

    func testExtractAccountIDFromNestedAuthClaim() {
        let payload = #"{"https://api.openai.com/auth":{"chatgpt_account_id":"acct_123"}}"#
        let token = makeUnsignedJWT(payload: payload)
        XCTAssertEqual(
            CodexAuthSupport.extractAccountID(idToken: token, accessToken: nil),
            "acct_123"
        )
    }

    func testParseChatGPTAuthDocumentRequiresRefreshToken() {
        let doc: [String: Any] = [
            "auth_mode": "chatgpt",
            "tokens": [
                "access_token": "access_only"
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: doc)
        XCTAssertThrowsError(try CodexAuthSupport.parseChatGPTAuthDocument(data))
    }

    func testParseChatGPTAuthDocumentAcceptsValidTokens() throws {
        let doc: [String: Any] = [
            "auth_mode": "chatgpt",
            "tokens": [
                "access_token": "access",
                "refresh_token": "refresh"
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: doc)
        let tokens = try CodexAuthSupport.parseChatGPTAuthDocument(data)
        XCTAssertEqual(tokens["refresh_token"] as? String, "refresh")
    }

    func testRevokeRequestBodyPrefersRefreshToken() {
        let body = CodexAuthSupport.revokeRequestBody(
            refreshToken: "refresh",
            accessToken: "access"
        )
        XCTAssertEqual(body?["token_type_hint"], "refresh_token")
        XCTAssertEqual(body?["token"], "refresh")
        XCTAssertEqual(body?["client_id"], CodexAuthSupport.oauthClientID)
    }

    func testNormalizedModelNameFallsBackWhenEmpty() {
        XCTAssertEqual(CodexAuthSupport.normalizedModelName(""), "gpt-5-codex")
        XCTAssertEqual(CodexAuthSupport.normalizedModelName("  gpt-5.5  "), "gpt-5.5")
    }

    private func makeUnsignedJWT(payload: String) -> String {
        let header = Data(#"{"alg":"none","typ":"JWT"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let body = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(header).\(body)."
    }
}
