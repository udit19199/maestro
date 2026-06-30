//
//  ClarifyTool.swift
//  zoro
//
//  Created by Antigravity on 19/06/26.
//

import Foundation
import FoundationModels

struct ClarifyTool: Tool {
    let name = "clarify"
    let description = "Ask the user a clarifying question when requirements are ambiguous, or when user input is needed to proceed. Suspends execution until the user replies."

    @Generable
    struct Arguments {
        @Guide(description: "The question to ask the user")
        var question: String
    }

    func call(arguments: Arguments) async throws -> String {
        let workspace = await WorkspaceManager.shared
        if let permissionError = await workspace.toolPermissionError(for: name) {
            return permissionError
        }

        if case .iMessage = await workspace.currentExecutionContext {
            return "Error: Clarifying questions are not supported over iMessage. Please include all required details in a single `zoro:` command."
        }

        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                workspace.clarifyContinuation = continuation
                workspace.activeClarificationQuestion = arguments.question
            }
        }
    }
}
