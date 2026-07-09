//
//  MailPriorityRanker.swift
//  zoro
//

import Foundation

struct RankedMailMessage: Sendable, Equatable {
    let summary: MailMessageSummary
    let accountLabel: String
    let rankScore: Int
}

/// Deterministic priority ranking for unified briefing inbox. Pure Swift, no networking.
enum MailPriorityRanker {
    static func rank(
        messages: [MailMessageSummary],
        accountLabels: [UUID: String],
        now: Date = Date()
    ) -> [RankedMailMessage] {
        messages
            .map { summary in
                RankedMailMessage(
                    summary: summary,
                    accountLabel: accountLabels[summary.accountId] ?? "mail",
                    rankScore: score(for: summary, now: now)
                )
            }
            .sorted { lhs, rhs in
                if lhs.rankScore != rhs.rankScore {
                    return lhs.rankScore > rhs.rankScore
                }
                return lhs.summary.receivedAt > rhs.summary.receivedAt
            }
    }

    static func topBriefingItems(
        from messages: [MailMessageSummary],
        accountLabels: [UUID: String],
        limit: Int = 8,
        now: Date = Date()
    ) -> [BriefingMailItem] {
        rank(messages: messages, accountLabels: accountLabels, now: now)
            .prefix(limit)
            .map { ranked in
                BriefingMailItem(
                    id: ranked.summary.id,
                    accountId: ranked.summary.accountId,
                    accountLabel: ranked.accountLabel,
                    sender: displaySender(ranked.summary.from),
                    subject: ranked.summary.subject,
                    snippet: ranked.summary.snippet,
                    receivedAt: ranked.summary.receivedAt,
                    isUnread: ranked.summary.isUnread
                )
            }
    }

    static func digestCounts(for messages: [MailMessageSummary]) -> (needsReply: Int, newsletters: Int, invites: Int) {
        var needsReply = 0
        var newsletters = 0
        var invites = 0

        for message in messages where message.isUnread {
            if CleanupHeuristics.isLikelyCalendarInvite(subject: message.subject, snippet: message.snippet) {
                invites += 1
            } else if CleanupHeuristics.isNewsletter(
                from: message.from,
                subject: message.subject,
                snippet: message.snippet
            ) {
                newsletters += 1
            } else if CleanupHeuristics.isLikelyNeedsReply(
                from: message.from,
                subject: message.subject,
                snippet: message.snippet
            ) {
                needsReply += 1
            }
        }

        return (needsReply, newsletters, invites)
    }

    static func formatDigestLine(for messages: [MailMessageSummary]) -> String {
        let counts = digestCounts(for: messages)
        var parts: [String] = []
        if counts.needsReply > 0 {
            parts.append("\(counts.needsReply) need reply")
        }
        if counts.newsletters > 0 {
            parts.append("\(counts.newsletters) newsletter\(counts.newsletters == 1 ? "" : "s")")
        }
        if counts.invites > 0 {
            parts.append("\(counts.invites) invite\(counts.invites == 1 ? "" : "s")")
        }
        if parts.isEmpty {
            return "No priority unread mail"
        }
        return parts.joined(separator: " · ")
    }

    private static func score(for summary: MailMessageSummary, now: Date) -> Int {
        var score = 0

        if summary.isUnread {
            score += 100
        }

        if CleanupHeuristics.isLikelyNeedsReply(
            from: summary.from,
            subject: summary.subject,
            snippet: summary.snippet
        ) {
            score += 80
        } else if CleanupHeuristics.isLikelyCalendarInvite(
            subject: summary.subject,
            snippet: summary.snippet
        ) {
            score += 50
        } else if CleanupHeuristics.isAutomatedNotification(
            from: summary.from,
            subject: summary.subject,
            snippet: summary.snippet
        ) {
            score += 20
        } else if CleanupHeuristics.isNewsletter(
            from: summary.from,
            subject: summary.subject,
            snippet: summary.snippet
        ) {
            score += 5
        } else {
            score += 40
        }

        let ageHours = max(0, now.timeIntervalSince(summary.receivedAt) / 3600)
        if ageHours < 6 {
            score += 30
        } else if ageHours < 24 {
            score += 20
        } else if ageHours < 72 {
            score += 10
        }

        return score
    }

    private static func displaySender(_ from: String) -> String {
        let trimmed = from.trimmingCharacters(in: .whitespacesAndNewlines)
        if let angleStart = trimmed.firstIndex(of: "<") {
            let name = trimmed[..<angleStart].trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                return name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        if let atIndex = trimmed.firstIndex(of: "@") {
            return String(trimmed[..<atIndex])
        }
        return trimmed
    }
}
