//
//  BriefingMailDigest.swift
//  zoro
//

import Foundation

enum BriefingMailDigestGenerator {
    static func generate(from messages: [MailMessageSummary]) -> String {
        return MailPriorityRanker.formatDigestLine(for: messages)
    }
}
