//
//  ProfileMemoryTool.swift
//  zoro
//

import Foundation
import FoundationModels

@MainActor
struct ProfileMemoryTool: Tool {
    let name = "update_user_memory"
    let description = "Save a durable fact or progress note about the user to their profile. Use for confirmed preferences, goals, or tutoring/planning progress."
    let executionContext: AgentExecutionContext

    @Generable
    struct Arguments {
        @Guide(description: "The fact or progress note to remember about the user")
        var fact: String

        @Guide(description: "Category: 'preference', 'goal', 'progress', or 'general'")
        var category: String?
    }

    func call(arguments: Arguments) async throws -> String {
        if let permissionError = SecurityPolicy.toolPermissionError(for: name, context: executionContext) {
            return permissionError
        }

        let trimmed = arguments.fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Error: fact text is empty."
        }

        let source: MemoryFactSource
        if let agentContext = WorkspaceManager.shared.activeAgentType {
            switch agentContext {
            case .planner: source = .planner
            case .teach: source = .teach
            default: source = .manual
            }
        } else {
            source = .manual
        }

        let notify = source != .planner && source != .teach
        let added = ProfileStore.shared.addFact(trimmed, source: source, notify: notify)
        if added != nil {
            return "Saved to user profile."
        }
        return "Fact already known or could not be saved."
    }
}
