//
//  TodoTool.swift
//  zoro
//

import Foundation
import FoundationModels

@MainActor
struct TodoTool: Tool {
    let name = "todo"
    let description = "Read or write Zoro's internal task list. Use this to break down complex tasks, track progress, and maintain focus. Pass 'todos' to write, omit it to read."
    let executionContext: AgentExecutionContext

    @Generable
    struct Arguments {
        @Guide(description: "A list of todo items to write or merge. Each item must contain 'id', 'content', and 'status'.")
        var todos: [WorkspaceManager.TodoItem]?

        @Guide(description: "If true, merges the provided items into the existing list. If false, replaces the list entirely.")
        var merge: Bool?
    }

    func call(arguments: Arguments) async throws -> String {
        if let permissionError = SecurityPolicy.toolPermissionError(for: name, context: executionContext) {
            return permissionError
        }

        let result: [WorkspaceManager.TodoItem]
        if let inputTodos = arguments.todos {
            result = WorkspaceManager.shared.updateTodos(inputTodos, merge: arguments.merge ?? false)
        } else {
            result = WorkspaceManager.shared.activeTodos
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(result)
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}
