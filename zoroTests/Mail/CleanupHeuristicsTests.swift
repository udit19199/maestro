//
//  CleanupHeuristicsTests.swift
//  zoroTests
//

import XCTest
@testable import zoro

final class CleanupHeuristicsTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    func testDetectsNewsletterBySenderPattern() {
        XCTAssertTrue(
            CleanupHeuristics.isNewsletter(
                from: "noreply@updates.medium.com",
                subject: "Stories for you",
                snippet: "Writers you follow published this week."
            )
        )
    }

    func testDetectsNewsletterBySubjectPattern() {
        XCTAssertTrue(
            CleanupHeuristics.isNewsletter(
                from: "hello@example.com",
                subject: "Your daily digest",
                snippet: "Top posts from today."
            )
        )
    }

    func testDetectsNewsletterByUnsubscribeSnippet() {
        XCTAssertTrue(
            CleanupHeuristics.isNewsletter(
                from: "hello@brand.com",
                subject: "Product updates",
                snippet: "Manage preferences or unsubscribe at any time."
            )
        )
    }

    func testNeedsReplyOnRePrefix() {
        XCTAssertTrue(
            CleanupHeuristics.isLikelyNeedsReply(
                from: "colleague@company.com",
                subject: "Re: Proposal",
                snippet: "Attached the latest draft."
            )
        )
    }

    func testNeedsReplyOnQuestionInSnippet() {
        XCTAssertTrue(
            CleanupHeuristics.isLikelyNeedsReply(
                from: "client@example.com",
                subject: "Timeline",
                snippet: "Could you confirm the delivery date?"
            )
        )
    }

    func testNeedsReplyFalseForNewsletter() {
        XCTAssertFalse(
            CleanupHeuristics.isLikelyNeedsReply(
                from: "news@mailchimp.com",
                subject: "Weekly newsletter",
                snippet: "Unsubscribe from this mailing list."
            )
        )
    }

    func testCalendarInviteDetection() {
        XCTAssertTrue(
            CleanupHeuristics.isLikelyCalendarInvite(
                subject: "Invitation: Quarterly planning",
                snippet: "When: Friday at 10am. Where: Room 4."
            )
        )
        XCTAssertTrue(
            CleanupHeuristics.isLikelyCalendarInvite(
                subject: "Updated invitation",
                snippet: "Attached invite.ics for your calendar."
            )
        )
    }

    func testAutomatedNotificationExcludesNewsletters() {
        XCTAssertTrue(
            CleanupHeuristics.isAutomatedNotification(
                from: "security@apple.com",
                subject: "Security alert",
                snippet: "Your Apple ID was used to sign in."
            )
        )
        XCTAssertFalse(
            CleanupHeuristics.isAutomatedNotification(
                from: "news@mailchimp.com",
                subject: "Weekly newsletter",
                snippet: "Unsubscribe anytime."
            )
        )
    }

    func testCleanupCandidateRequiresAgeAndNewsletter() {
        let recentNewsletter = Date().addingTimeInterval(-2 * 24 * 60 * 60)
        XCTAssertFalse(
            CleanupHeuristics.isCleanupCandidate(
                from: "digest@beehiiv.com",
                subject: "Weekly digest",
                snippet: "Unsubscribe",
                receivedAt: recentNewsletter,
                now: fixedNow
            )
        )

        let oldNewsletter = fixedNow.addingTimeInterval(-10 * 24 * 60 * 60)
        XCTAssertTrue(
            CleanupHeuristics.isCleanupCandidate(
                from: "digest@beehiiv.com",
                subject: "Weekly digest",
                snippet: "Unsubscribe",
                receivedAt: oldNewsletter,
                now: fixedNow
            )
        )

        let oldPersonal = fixedNow.addingTimeInterval(-10 * 24 * 60 * 60)
        XCTAssertFalse(
            CleanupHeuristics.isCleanupCandidate(
                from: "friend@example.com",
                subject: "Catch up soon?",
                snippet: "Let's grab coffee next week.",
                receivedAt: oldPersonal,
                now: fixedNow
            )
        )
    }
}
