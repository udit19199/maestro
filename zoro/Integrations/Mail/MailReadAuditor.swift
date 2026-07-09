//
//  MailReadAuditor.swift
//  zoro
//
//  Hard enforcement: block assistant responses that cite unread mail content without a read_message call.
//

import Foundation

@MainActor
enum MailReadAuditor {
    struct PromptMailState {
        var hadIndexOnlyFetch: Bool = false
        var hadFullRead: Bool = false
        var indexMessageIds: Set<String> = []
    }

    private static var promptState = PromptMailState()

    static func resetPromptState() {
        promptState = PromptMailState()
    }

    static func recordIndexFetch(output: String) {
        promptState.hadIndexOnlyFetch = true
        promptState.indexMessageIds.formUnion(MailParsing.extractIndexMessageIds(from: output))
    }

    static func recordFullRead() {
        promptState.hadFullRead = true
    }

    static func auditAssistantResponse(_ response: String, userPrompt: String) -> String {
        guard !MailManager.shared.configuredAccounts().isEmpty else { return response }

        var issues: [String] = []
        let readKeys = MailManager.shared.sessionReadKeys

        let citedIds = MailParsing.extractMessageIds(from: response)
        let unverifiedIds = citedIds.filter { id in
            !readKeys.contains(where: { $0.hasSuffix("|\(id)") })
        }
        if !unverifiedIds.isEmpty {
            issues.append("Cites message ID(s) not fully read this session: \(unverifiedIds.joined(separator: ", ")).")
        }

        let emailPrompt = MailParsing.userPromptMentionsEmail(userPrompt)
        let looksLikeSummary = MailParsing.looksLikeEmailSummary(response)

        if emailPrompt && looksLikeSummary && !promptState.hadFullRead {
            issues.append("Appears to summarize email without calling read_message this turn.")
        }

        if promptState.hadIndexOnlyFetch && looksLikeSummary && !promptState.hadFullRead {
            issues.append("Summarization detected after index-only list/search without a subsequent read_message call.")
        }

        if issues.isEmpty { return response }

        return """
        ⚠️ Mail verification failed — this response was blocked because it may contain unsourced or incomplete email content.

        Issues detected:
        \(issues.map { "• \($0)" }.joined(separator: "\n"))

        Zoro requires full message bodies via read_message before summarizing email. Please retry your request.

        Messages fully read this session: \(readKeys.isEmpty ? "none" : readKeys.sorted().joined(separator: ", "))
        """
    }
}
