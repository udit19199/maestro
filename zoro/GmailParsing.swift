//
//  GmailParsing.swift
//  zoro
//
//  Pure parsing helpers shared by GmailService and unit tests.
//

import Foundation

enum GmailParsing {
    static func decodeBase64URLData(_ input: String) -> Data? {
        var base64 = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = 4 - (base64.count % 4)
        if padding < 4 {
            base64 += String(repeating: "=", count: padding)
        }
        return Data(base64Encoded: base64)
    }

    static func decodeBase64URL(_ input: String) -> String? {
        guard let data = decodeBase64URLData(input) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func stripHTML(_ html: String) -> String {
        html
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func extractMessageIds(from text: String) -> [String] {
        let patterns = [
            /id=([a-f0-9]+)/,
            /(?i)message[_ ]?id[:\s]+([a-f0-9]+)/,
            /\[([a-f0-9]{10,})\]/
        ]
        var ids = Set<String>()
        for pattern in patterns {
            for match in text.matches(of: pattern) {
                ids.insert(String(match.1))
            }
        }
        return Array(ids)
    }

    static func extractIndexMessageIds(from toolOutput: String) -> [String] {
        extractMessageIds(from: toolOutput)
    }

    static func userPromptMentionsEmail(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        let keywords = [
            "gmail", "email", "e-mail", "inbox", "mail from", "message from",
            "unread", "thread", "reply to", "sent mail", "my emails"
        ]
        return keywords.contains { lower.contains($0) }
    }

    static func looksLikeEmailSummary(_ response: String) -> Bool {
        let lower = response.lowercased()
        let summarySignals = [
            "the email", "this email", "the message says", "they wrote",
            "subject line", "in the email", "email from", "summariz",
            "unread message", "inbox", "attached", "wrote:"
        ]
        let signalCount = summarySignals.filter { lower.contains($0) }.count
        return signalCount >= 2 || (signalCount >= 1 && lower.contains("from:"))
    }
}
