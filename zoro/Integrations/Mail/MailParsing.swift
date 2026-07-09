//
//  MailParsing.swift
//  zoro
//
//  Pure parsing helpers for multi-provider mail tool output and read auditing.
//

import Foundation

enum MailParsing {
    static func extractMessageIds(from text: String) -> [String] {
        var ids = Set<String>()
        ids.formUnion(GmailParsing.extractMessageIds(from: text))

        let imapPattern = /imap:\/\/[^\s\])"'<>]+/
        for match in text.matches(of: imapPattern) {
            ids.insert(String(match.output))
        }

        let labeledPattern = /(?i)message[_ ]?id:\s*(\S+)/
        for match in text.matches(of: labeledPattern) {
            ids.insert(String(match.1))
        }

        return Array(ids)
    }

    static func extractReadKeys(from text: String) -> [String] {
        var keys = Set<String>()
        let pattern = /([0-9A-Fa-f-]{36})\|(\S+)/
        for match in text.matches(of: pattern) {
            keys.insert("\(match.1)|\(match.2)")
        }
        return Array(keys)
    }

    static func extractIndexMessageIds(from toolOutput: String) -> [String] {
        extractMessageIds(from: toolOutput)
    }

    static func userPromptMentionsEmail(_ prompt: String) -> Bool {
        GmailParsing.userPromptMentionsEmail(prompt)
    }

    static func looksLikeEmailSummary(_ response: String) -> Bool {
        GmailParsing.looksLikeEmailSummary(response)
    }
}
