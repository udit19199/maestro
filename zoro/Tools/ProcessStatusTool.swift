//
//  ProcessStatusTool.swift
//  zoro
//

import Foundation
import FoundationModels

@MainActor
struct ProcessStatusTool: Tool {
    let name = "get_process_status"
    let description = "Check status and recent output of a background terminal task by task ID."
    let executionContext: AgentExecutionContext

    @Generable
    struct Arguments {
        @Guide(description: "The task ID returned when the command was started (e.g. task_abc123)")
        var taskId: String
    }

    func call(arguments: Arguments) async throws -> String {
        if let permissionError = SecurityPolicy.toolPermissionError(for: name, context: executionContext) {
            return permissionError
        }

        let workspace = WorkspaceManager.shared
        workspace.pruneTerminatedProcesses()

        guard let running = workspace.activeProcesses[arguments.taskId] else {
            return "Error: No active process with ID '\(arguments.taskId)'."
        }

        let output = running.getAvailableOutput()
        let status = running.isRunning ? "running" : "exited"
        let elapsed = Int(Date().timeIntervalSince(running.startDate))
        return """
        Task \(arguments.taskId): \(status) (\(elapsed)s)
        Command: \(running.command)

        Output:
        \(output.isEmpty ? "(no output yet)" : output)
        """
    }
}
