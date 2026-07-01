//
//  GmailParsingTests.swift
//  zoroTests
//

import XCTest
@testable import zoro

final class GmailParsingTests: XCTestCase {
    func testDecodeBase64URLRoundTrip() {
        let original = "Hello, Gmail!"
        let encoded = Data(original.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        XCTAssertEqual(GmailParsing.decodeBase64URL(encoded), original)
    }

    func testStripHTMLRemovesTags() {
        let html = "<p>Hello <strong>world</strong></p>"
        XCTAssertEqual(GmailParsing.stripHTML(html), "Hello world")
    }

    func testExtractMessageIdsFromToolOutput() {
        let output = """
        [1/2] id=18abc123def thread_id=18thread99
        from: alice@example.com
        """
        let ids = GmailParsing.extractMessageIds(from: output)
        XCTAssertTrue(ids.contains("18abc123def"))
    }

    func testUserPromptMentionsEmail() {
        XCTAssertTrue(GmailParsing.userPromptMentionsEmail("Summarize my latest gmail from Alice"))
        XCTAssertFalse(GmailParsing.userPromptMentionsEmail("Run npm test in the workspace"))
    }

    func testLooksLikeEmailSummary() {
        let summary = "The email from Alice says the invoice is due Friday. The subject line mentions payment."
        XCTAssertTrue(GmailParsing.looksLikeEmailSummary(summary))
    }
}
