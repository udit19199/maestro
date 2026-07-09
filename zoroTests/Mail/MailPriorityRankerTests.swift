//
//  MailPriorityRankerTests.swift
//  zoroTests
//

import XCTest
@testable import zoro

final class MailPriorityRankerTests: XCTestCase {
    private let accountA = UUID(uuidString: "A1000000-0000-0000-0000-000000000001")!
    private let accountB = UUID(uuidString: "A1000000-0000-0000-0000-000000000002")!
    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeSummary(
        id: String = "msg-1",
        accountId: UUID? = nil,
        from: String = "alice@example.com",
        subject: String = "Hello",
        snippet: String = "",
        receivedAt: Date? = nil,
        isUnread: Bool = true
    ) -> MailMessageSummary {
        MailMessageSummary(
            id: id,
            threadId: nil,
            accountId: accountId ?? accountA,
            from: from,
            to: "me@example.com",
            subject: subject,
            snippet: snippet,
            receivedAt: receivedAt ?? fixedNow.addingTimeInterval(-3600),
            isUnread: isUnread,
            labelIds: []
        )
    }

    func testReplyEmailsRankAboveNewsletters() {
        let reply = makeSummary(
            id: "reply",
            from: "boss@company.com",
            subject: "Re: Contract review",
            snippet: "Can you look at section 4 before Monday?"
        )
        let newsletter = makeSummary(
            id: "newsletter",
            accountId: accountB,
            from: "noreply@medium.com",
            subject: "Your daily digest",
            snippet: "Top stories for you. Unsubscribe here."
        )

        let ranked = MailPriorityRanker.rank(
            messages: [newsletter, reply],
            accountLabels: [accountA: "work", accountB: "personal"],
            now: fixedNow
        )

        XCTAssertEqual(ranked.first?.summary.id, "reply")
        XCTAssertGreaterThan(ranked[0].rankScore, ranked[1].rankScore)
    }

    func testDigestCountsCategorizesUnreadMessages() {
        let messages = [
            makeSummary(
                id: "reply",
                subject: "Re: Budget",
                snippet: "Can you review this by Friday?"
            ),
            makeSummary(
                id: "newsletter",
                from: "newsletter@substack.com",
                subject: "Weekly roundup",
                snippet: "Unsubscribe from this list."
            ),
            makeSummary(
                id: "invite",
                subject: "Invitation: Team sync",
                snippet: "When: Monday at 2pm. Where: Zoom."
            ),
            makeSummary(
                id: "read",
                subject: "Old thread",
                snippet: "Thanks!",
                isUnread: false
            ),
        ]

        let counts = MailPriorityRanker.digestCounts(for: messages)

        XCTAssertEqual(counts.needsReply, 1)
        XCTAssertEqual(counts.newsletters, 1)
        XCTAssertEqual(counts.invites, 1)
    }

    func testFormatDigestLineJoinsCounts() {
        let messages = [
            makeSummary(subject: "Re: Contract", snippet: "Please let me know your thoughts."),
            makeSummary(
                from: "digest@beehiiv.com",
                subject: "Daily digest",
                snippet: "View in browser or unsubscribe."
            ),
        ]

        let line = MailPriorityRanker.formatDigestLine(for: messages)

        XCTAssertTrue(line.contains("1 need reply"))
        XCTAssertTrue(line.contains("1 newsletter"))
    }

    func testFormatDigestLineEmptyWhenNoPriorityUnread() {
        let messages = [
            makeSummary(
                from: "digest@beehiiv.com",
                subject: "Daily digest",
                snippet: "Unsubscribe",
                isUnread: false
            ),
        ]

        XCTAssertEqual(
            MailPriorityRanker.formatDigestLine(for: messages),
            "No priority unread mail"
        )
    }

    func testTopBriefingItemsRespectsLimitAndLabels() {
        let messages = (1...10).map { index in
            makeSummary(
                id: "msg-\(index)",
                subject: "Re: Thread \(index)",
                snippet: "Can you follow up on item \(index)?"
            )
        }

        let items = MailPriorityRanker.topBriefingItems(
            from: messages,
            accountLabels: [accountA: "work@gmail"],
            limit: 3,
            now: fixedNow
        )

        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.first?.accountLabel, "work@gmail")
        XCTAssertEqual(items.first?.sender, "alice")
    }

    func testDisplaySenderParsesFriendlyName() {
        let messages = [
            makeSummary(
                from: "\"John Smith\" <john@example.com>",
                subject: "Hello"
            ),
        ]

        let items = MailPriorityRanker.topBriefingItems(
            from: messages,
            accountLabels: [accountA: "work"],
            limit: 1,
            now: fixedNow
        )

        XCTAssertEqual(items.first?.sender, "John Smith")
    }
}
