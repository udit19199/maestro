//
//  CommandLineTool.swift
//  zoro
//
//  Created by Udit Agarwal on 19/06/26.
//

import FoundationModels
import Foundation

struct CommandLineTool: Tool {
    let name = "run_terminal_command"
    let description = "Execute a terminal command or script inside the project's workspace (e.g. running tests, building code, starting dev servers)."

    @Generable
    struct Arguments {
        @Guide(description: "The exact zsh shell command to execute")
        var command: String

        @Guide(description: "If true, runs the command in the background immediately. Use true for servers, test watchers, or blocking processes. Defaults to false.")
        var runInBackground: Bool
    }

    func call(arguments: Arguments) async throws -> String {
        let workspace = await WorkspaceManager.shared
        if let permissionError = await workspace.toolPermissionError(for: name) {
            return permissionError
        }

        if arguments.runInBackground {
            return try await workspace.runCommandBackground(arguments.command)
        } else {
            return try await workspace.runCommand(arguments.command)
        }
    }
}
