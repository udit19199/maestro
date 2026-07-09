//
//  MailReadAuditorTests.swift
//  zoroTests
//

import XCTest
@testable import zoro

@MainActor
final class MailReadAuditorTests: XCTestCase {
    private var testAccountId: UUID!
    private var addedAccount = false

    override func setUp() {
        super.setUp()
        MailReadAuditor.resetPromptState()
        MailManager.shared.clearSessionReads()

        testAccountId = UUID()
        let account = MailAccount(
            id: testAccountId,
            email: "auditor-test@example.com",
            displayName: "Auditor Test",
            provider: .gmail
        )
        MailAccountStore.shared.addAccount(account)
        MailAccountKeychain.saveGmailRefreshToken("test-refresh-token", accountId: testAccountId)
        addedAccount = true
    }

    override func tearDown() {
        if addedAccount, let testAccountId {
            MailAccountStore.shared.removeAccount(id: testAccountId)
            MailAccountKeychain.deleteGmailCredentials(for: testAccountId)
        }
        MailReadAuditor.resetPromptState()
        MailManager.shared.clearSessionReads()
        super.tearDown()
    }

    func testNoConfiguredAccountsPassesThrough() {
        MailAccountStore.shared.removeAccount(id: testAccountId)
        MailAccountKeychain.deleteGmailCredentials(for: testAccountId)
        addedAccount = false

        let response = "The email from Alice says the invoice is due Friday. The subject line mentions payment."
        let audited = MailReadAuditor.auditAssistantResponse(
            response,
            userPrompt: "Summarize my latest email from Alice"
        )

        XCTAssertEqual(audited, response)
    }

    func testBlocksSummaryWithoutRead() {
        let response = """
        The email from Alice says the invoice is due Friday. The subject line mentions payment.
        """
        let audited = MailReadAuditor.auditAssistantResponse(
            response,
            userPrompt: "Summarize my latest email from Alice"
        )

        XCTAssertTrue(audited.contains("Mail verification failed"))
        XCTAssertTrue(audited.contains("without calling read_message"))
    }

    func testAllowsResponseAfterFullRead() {
        MailReadAuditor.recordIndexFetch(output: "[1/1] id=abc123 from: alice@example.com")
        MailReadAuditor.recordFullRead()

        let response = """
        The email from Alice says the invoice is due Friday. The subject line mentions payment.
        """
        let audited = MailReadAuditor.auditAssistantResponse(
            response,
            userPrompt: "Summarize my latest email from Alice"
        )

        XCTAssertEqual(audited, response)
    }

    func testBlocksIndexOnlySummarization() {
        MailReadAuditor.recordIndexFetch(output: "[1/1] id=abc123 from: alice@example.com")

        let response = """
        The email from Alice says the invoice is due Friday. The subject line mentions payment.
        """
        let audited = MailReadAuditor.auditAssistantResponse(
            response,
            userPrompt: "What did Alice write?"
        )

        XCTAssertTrue(audited.contains("Mail verification failed"))
        XCTAssertTrue(audited.contains("index-only"))
    }

    func testBlocksUnverifiedMessageIdCitation() {
        let response = "Message id=abc123def456 says the contract is ready."

        let audited = MailReadAuditor.auditAssistantResponse(
            response,
            userPrompt: "What does that email say?"
        )

        XCTAssertTrue(audited.contains("Mail verification failed"))
        XCTAssertTrue(audited.contains("abc123def456"))
    }

    func testAllowsVerifiedMessageIdCitation() {
        MailManager.shared.recordMessagesRead(accountId: testAccountId, messageIds: ["verified456"])
        MailReadAuditor.recordFullRead()

        let response = "Message id=verified456 confirms the meeting time."

        let audited = MailReadAuditor.auditAssistantResponse(
            response,
            userPrompt: "Summarize that email"
        )

        XCTAssertEqual(audited, response)
    }
}
