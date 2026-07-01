//
//  GmailReadAuditor.swift
//  zoro
//
//  Hard enforcement: block assistant responses that cite unread Gmail content.
//

import Foundation

@MainActor
enum GmailReadAuditor {
    struct PromptGmailState {
        var hadIndexOnlyFetch: Bool = false
        var hadFullRead: Bool = false
        var indexMessageIds: Set<String> = []
    }

    private static var promptState = PromptGmailState()

    static func resetPromptState() {
        promptState = PromptGmailState()
    }

    static func recordIndexFetch(output: String) {
        promptState.hadIndexOnlyFetch = true
        promptState.indexMessageIds.formUnion(GmailParsing.extractIndexMessageIds(from: output))
    }

    static func recordFullRead() {
        promptState.hadFullRead = true
    }

    static func auditAssistantResponse(_ response: String, userPrompt: String) -> String {
        guard GmailAuthManager.shared.isConnected else { return response }

        var issues: [String] = []
        let readIds = GmailManager.shared.sessionReadMessageIds

        let citedIds = GmailParsing.extractMessageIds(from: response)
        let unverifiedIds = citedIds.filter { !readIds.contains($0) }
        if !unverifiedIds.isEmpty {
            issues.append("Cites message ID(s) not fully read this session: \(unverifiedIds.joined(separator: ", ")).")
        }

        let emailPrompt = GmailParsing.userPromptMentionsEmail(userPrompt)
        let looksLikeSummary = GmailParsing.looksLikeEmailSummary(response)

        if emailPrompt && looksLikeSummary && !promptState.hadFullRead {
            issues.append("Appears to summarize email without calling read_message, read_messages, or read_thread this turn.")
        }

        if promptState.hadIndexOnlyFetch && looksLikeSummary && !promptState.hadFullRead {
            issues.append("Summarization detected after index-only search/list without a subsequent read_* call.")
        }

        if issues.isEmpty { return response }

        return """
        ⚠️ Gmail verification failed — this response was blocked because it may contain unsourced or incomplete email content.

        Issues detected:
        \(issues.map { "• \($0)" }.joined(separator: "\n"))

        Zoro requires full message bodies via read_message, read_messages, or read_thread before summarizing email. Please retry your request.

        Message IDs fully read this session: \(readIds.isEmpty ? "none" : readIds.sorted().joined(separator: ", "))
        """
    }
}
