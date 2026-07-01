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
        if await WorkspaceManager.shared.isIMessageContext {
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
