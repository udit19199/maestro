//
//  AgentHandoffDetector.swift
//  zoro
//

import Foundation

enum AgentHandoffDetector {
    struct Suggestion: Equatable {
        let agentType: AgentType
        let message: String
    }

    static func suggest(for userMessage: String) -> Suggestion? {
        let lower = userMessage.lowercased()

        let researchKeywords = ["research", "look up", "find out", "search the web", "deep dive", "investigate"]
        if researchKeywords.contains(where: { lower.contains($0) }) {
            return Suggestion(agentType: .research, message: "This looks like research — start a Research chat?")
        }

        let plannerKeywords = ["schedule", "calendar", "plan my day", "plan my week", "reminder", "meeting", "agenda"]
        if plannerKeywords.contains(where: { lower.contains($0) }) {
            return Suggestion(agentType: .planner, message: "This looks like planning — start a Planner chat?")
        }

        let teachKeywords = ["teach me", "learn ", "explain ", "tutorial", "how do i", "help me understand"]
        if teachKeywords.contains(where: { lower.contains($0) }) {
            return Suggestion(agentType: .teach, message: "This looks like learning — start a Teach chat?")
        }

        return nil
    }
}
