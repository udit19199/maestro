//
//  CleanupHeuristics.swift
//  zoro
//

import Foundation

/// Pure heuristics for newsletter detection and cleanup candidacy. No networking.
enum CleanupHeuristics {
    private static let newsletterSenderPatterns: [String] = [
        "newsletter",
        "digest",
        "noreply",
        "no-reply",
        "donotreply",
        "do-not-reply",
        "mailer-daemon",
        "notifications@",
        "updates@",
        "news@",
        "marketing@",
        "promo@",
        "substack.com",
        "mailchimp",
        "sendgrid",
        "constantcontact",
        "beehiiv",
        "medium.com",
        "linkedin.com",
        "github.com",
    ]

    private static let newsletterSubjectPatterns: [String] = [
        "newsletter",
        "daily digest",
        "weekly digest",
        "your daily",
        "top stories",
        "roundup",
        "unsubscribe",
        "view in browser",
        "mailing list",
    ]

    private static let notificationSenderPatterns: [String] = [
        "alert@",
        "security@",
        "notify@",
        "notification",
        "account-security",
        "no-reply@accounts.",
        "mail-noreply@",
    ]

    private static let notificationSubjectPatterns: [String] = [
        "security alert",
        "sign-in",
        "sign in",
        "verification code",
        "password reset",
        "new login",
        "receipt",
        "order confirmation",
        "shipping update",
        "delivery update",
    ]

    private static let calendarSubjectPatterns: [String] = [
        "invitation:",
        "invite:",
        "meeting invite",
        "calendar invite",
        "accepted:",
        "declined:",
        "updated invitation",
        "event reminder",
    ]

    static func isNewsletter(from: String, subject: String, snippet: String) -> Bool {
        let haystack = normalizedHaystack(from: from, subject: subject, snippet: snippet)
        if newsletterSenderPatterns.contains(where: { haystack.contains($0) }) {
            return true
        }
        if newsletterSubjectPatterns.contains(where: { haystack.contains($0) }) {
            return true
        }
        if haystack.contains("unsubscribe") || haystack.contains("manage preferences") {
            return true
        }
        return false
    }

    static func isAutomatedNotification(from: String, subject: String, snippet: String = "") -> Bool {
        let haystack = normalizedHaystack(from: from, subject: subject, snippet: snippet)
        if isNewsletter(from: from, subject: subject, snippet: snippet) {
            return false
        }
        if notificationSenderPatterns.contains(where: { haystack.contains($0) }) {
            return true
        }
        return notificationSubjectPatterns.contains(where: { haystack.contains($0) })
    }

    static func isLikelyCalendarInvite(subject: String, snippet: String = "") -> Bool {
        let haystack = "\(subject) \(snippet)".lowercased()
        if calendarSubjectPatterns.contains(where: { haystack.contains($0) }) {
            return true
        }
        return haystack.contains(".ics") || haystack.contains("when:") && haystack.contains("where:")
    }

    static func isLikelyNeedsReply(from: String, subject: String, snippet: String) -> Bool {
        if isNewsletter(from: from, subject: subject, snippet: snippet) {
            return false
        }
        if isAutomatedNotification(from: from, subject: subject, snippet: snippet) {
            return false
        }

        let fromLower = from.lowercased()
        if fromLower.contains("noreply") || fromLower.contains("no-reply") || fromLower.contains("donotreply") {
            return false
        }

        let subjectLower = subject.lowercased()
        if subjectLower.hasPrefix("re:") || subjectLower.hasPrefix("fwd:") {
            return true
        }

        let combined = "\(subject) \(snippet)".lowercased()
        if combined.contains("?") {
            return true
        }
        let replyPhrases = [
            "can you",
            "could you",
            "please review",
            "please let me know",
            "waiting for your",
            "need your",
            "follow up",
            "following up",
        ]
        return replyPhrases.contains(where: { combined.contains($0) })
    }

    /// Weekly cleanup candidates: newsletters older than the given age threshold.
    static func isCleanupCandidate(
        from: String,
        subject: String,
        snippet: String,
        receivedAt: Date,
        minimumAge: TimeInterval = 7 * 24 * 60 * 60,
        now: Date = Date()
    ) -> Bool {
        guard now.timeIntervalSince(receivedAt) >= minimumAge else { return false }
        return isNewsletter(from: from, subject: subject, snippet: snippet)
    }

    static func isCleanupCandidate(_ summary: MailMessageSummary, minimumAge: TimeInterval = 7 * 24 * 60 * 60) -> Bool {
        isCleanupCandidate(
            from: summary.from,
            subject: summary.subject,
            snippet: summary.snippet,
            receivedAt: summary.receivedAt,
            minimumAge: minimumAge
        )
    }

    private static func normalizedHaystack(from: String, subject: String, snippet: String) -> String {
        "\(from) \(subject) \(snippet)".lowercased()
    }
}
