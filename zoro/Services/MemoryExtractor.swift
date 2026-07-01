//
//  MemoryExtractor.swift
//  zoro
//

import Foundation

enum MemoryExtractor {
    private static let highConfidencePatterns: [(prefix: String, transform: (String) -> String)] = [
        ("my name is ", { "Name: \($0.capitalized)" }),
        ("i am ", { "User is \($0)" }),
        ("i'm ", { "User is \($0)" }),
        ("i work at ", { "Works at \($0)" }),
        ("i live in ", { "Lives in \($0)" }),
        ("i prefer ", { "Prefers \($0)" }),
        ("my timezone is ", { "Timezone: \($0)" }),
        ("call me ", { "Preferred name: \($0.capitalized)" })
    ]

    /// Extracts high-confidence user-stated facts from recent conversation turns.
    static func extractFacts(from messages: [StoredMessage]) -> [String] {
        let userMessages = messages
            .filter { $0.role == .user }
            .suffix(6)
            .map(\.content)

        var extracted: [String] = []
        for message in userMessages {
            let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = normalized.lowercased()

            for pattern in highConfidencePatterns where lower.hasPrefix(pattern.prefix) {
                let remainder = String(normalized.dropFirst(pattern.prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
                guard !remainder.isEmpty, remainder.count <= 120 else { continue }
                let fact = pattern.transform(remainder)
                if !extracted.contains(where: { $0.caseInsensitiveCompare(fact) == .orderedSame }) {
                    extracted.append(fact)
                }
            }
        }
        return extracted
    }

    @MainActor
    static func processConversation(_ conversation: Conversation) {
        guard conversation.source == .desktop else { return }
        let facts = extractFacts(from: conversation.messages)
        guard !facts.isEmpty else { return }

        var addedAny = false
        for fact in facts {
            if ProfileStore.shared.addFact(fact, source: .auto, notify: false) != nil {
                addedAny = true
            }
        }
        if addedAny {
            ProfileStore.shared.showMemoryUpdatedBanner = true
        }
    }
}
