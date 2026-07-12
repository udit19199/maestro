//
//  ClarifyTool.swift
//  zoro
//

import Foundation
import FoundationModels

@MainActor
struct ClarifyTool: Tool {
    let name = "clarify"
    let description = "Ask the user a clarifying question when requirements are ambiguous, or when user input is needed to proceed. Suspends execution until the user replies."
    let executionContext: AgentExecutionContext

    @Generable
    struct Arguments {
        @Guide(description: "The question to ask the user")
        var question: String
    }

    func call(arguments: Arguments) async throws -> String {
        if executionContext.isRemote {
            return "Cannot ask clarifying questions via iMessage. Make a reasonable assumption based on context and proceed."
        }

        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                WorkspaceManager.shared.clarifyContinuation = continuation
                WorkspaceManager.shared.activeClarificationQuestion = arguments.question
            }
        }
    }
}
