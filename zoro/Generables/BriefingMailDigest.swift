//
//  BriefingMailDigest.swift
//  zoro
//

import Foundation
import FoundationModels

@Generable
struct BriefingMailDigest {
    @Guide(description: "One-line inbox digest, e.g. '2 need reply · 5 newsletters · 1 invite'")
    var digestLine: String

    @Guide(description: "Count of unread messages likely needing a reply")
    var needsReplyCount: Int

    @Guide(description: "Count of unread newsletter-style messages")
    var newsletterCount: Int

    @Guide(description: "Count of unread calendar invites or meeting-related messages")
    var inviteCount: Int
}

enum BriefingMailDigestGenerator {
    static func generate(from messages: [MailMessageSummary]) async -> String {
        let template = MailPriorityRanker.formatDigestLine(for: messages)
        guard !messages.isEmpty else { return template }

        let availability = SystemLanguageModel.default.availability
        if case .available = availability {
            if let generated = await generateWithFoundationModels(messages: messages) {
                return generated
            }
        }

        return template
    }

    private static func generateWithFoundationModels(messages: [MailMessageSummary]) async -> String? {
        let counts = MailPriorityRanker.digestCounts(for: messages)
        let sampleLines = messages.prefix(12).map { summary in
            "- from: \(summary.from); subject: \(summary.subject); snippet: \(summary.snippet)"
        }.joined(separator: "\n")

        let prompt = """
        You are summarizing a user's unread mail index for a morning briefing dashboard.
        Produce a concise one-line digest and accurate category counts.

        Deterministic baseline counts:
        needs_reply: \(counts.needsReply)
        newsletters: \(counts.newsletters)
        invites: \(counts.invites)

        Unread messages (snippets only):
        \(sampleLines)

        Keep digestLine under 80 characters. Use middle dots (·) between segments when multiple categories apply.
        """

        do {
            let session = LanguageModelSession(model: SystemLanguageModel.default)
            let response = try await session.respond(to: prompt, generating: BriefingMailDigest.self)
            let line = response.content.digestLine.trimmingCharacters(in: .whitespacesAndNewlines)
            return line.isEmpty ? nil : line
        } catch {
            return nil
        }
    }
}
