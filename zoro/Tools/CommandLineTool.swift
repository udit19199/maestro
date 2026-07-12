//
//  CommandLineTool.swift
//  zoro
//

import FoundationModels
import Foundation

@MainActor
struct CommandLineTool: Tool {
    let name = "run_terminal_command"
    let description = "Propose a terminal command to run in the workspace. Does not execute until the user confirms in the app."
    let executionContext: AgentExecutionContext

    @Generable
    struct Arguments {
        @Guide(description: "The exact zsh shell command to execute")
        var command: String

        @Guide(description: "If true, runs in background after user confirms. Defaults to false.")
        var runInBackground: Bool
    }

    func call(arguments: Arguments) async throws -> String {
        if let permissionError = SecurityPolicy.toolPermissionError(for: name, context: executionContext) {
            return permissionError
        }

        let trimmed = arguments.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Error: Command is empty."
        }

        guard WorkspaceManager.shared.workspaceURL != nil else {
            return "Error: No workspace directory selected."
        }

        let pending = PendingShellCommand(
            id: UUID(),
            command: trimmed,
            runInBackground: arguments.runInBackground,
            conversationID: WorkspaceManager.shared.activeConversationID
        )
        WorkspaceManager.shared.setPendingShellCommand(pending)

        return """
        Command staged — NOT executed. Waiting for user confirmation in Zoro.

        pending_shell_id: \(pending.id.uuidString)
        command: \(trimmed)
        background: \(arguments.runInBackground)

        Tell the user to confirm or cancel the command in the app before it runs.
        """
    }
}
