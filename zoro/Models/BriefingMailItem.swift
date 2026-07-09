//
//  BriefingMailItem.swift
//  zoro
//

import Foundation

struct BriefingMailItem: Identifiable, Equatable, Sendable {
    let id: String
    let accountId: UUID
    let accountLabel: String
    let sender: String
    let subject: String
    let snippet: String
    let receivedAt: Date
    let isUnread: Bool

    var composerPrompt: String {
        "Summarize the email from \(sender) about \"\(subject)\"."
    }
}

enum BriefingInboxState: Equatable, Sendable {
    case loading
    case noAccounts
    case empty(message: String)
    case loaded
    case error(message: String)
}

extension BriefingMailItem {
    static let previewSamples: [BriefingMailItem] = [
        BriefingMailItem(
            id: "1",
            accountId: UUID(uuidString: "A1000000-0000-0000-0000-000000000001")!,
            accountLabel: "work@gmail",
            sender: "John Smith",
            subject: "Re: Contract review",
            snippet: "Can you look at section 4 before Monday?",
            receivedAt: Date().addingTimeInterval(-7200),
            isUnread: true
        ),
        BriefingMailItem(
            id: "2",
            accountId: UUID(uuidString: "A1000000-0000-0000-0000-000000000002")!,
            accountLabel: "icloud",
            sender: "Apple",
            subject: "Security alert",
            snippet: "Your Apple ID was used to sign in on a Mac.",
            receivedAt: Date().addingTimeInterval(-14400),
            isUnread: true
        ),
        BriefingMailItem(
            id: "3",
            accountId: UUID(uuidString: "A1000000-0000-0000-0000-000000000003")!,
            accountLabel: "personal@gmail",
            sender: "Medium Daily Digest",
            subject: "Stories for you",
            snippet: "Top posts from writers you follow this week.",
            receivedAt: Date().addingTimeInterval(-86400),
            isUnread: true
        )
    ]
}
