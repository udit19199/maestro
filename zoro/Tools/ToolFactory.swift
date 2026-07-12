//
//  ToolFactory.swift
//  zoro
//
//  Sole production constructor for agent tools. Bakes AgentExecutionContext into each tool.
//

import Foundation
import FoundationModels

enum ToolFactory {
    /// Builds the tool set for an agent turn. Context is immutable on each tool instance.
    @MainActor
    static func tools(for agentType: AgentType, executionContext: AgentExecutionContext) -> [any Tool] {
        switch agentType {
        case .default:
            return [
                CommandLineTool(executionContext: executionContext),
                ProcessStatusTool(executionContext: executionContext),
                ListDirectoryTool(executionContext: executionContext),
                ReadFileTool(executionContext: executionContext),
                WriteFileTool(executionContext: executionContext),
                PatchTool(executionContext: executionContext),
                SearchFilesTool(executionContext: executionContext),
                CurrentTimeTool(),
                ClarifyTool(executionContext: executionContext),
                TodoTool(executionContext: executionContext),
                EventKitTool(executionContext: executionContext),
                AppleNotesTool(executionContext: executionContext),
                TavilySearchTool(executionContext: executionContext),
                IMessageTool(executionContext: executionContext),
                ProfileMemoryTool(executionContext: executionContext),
                MailTool(executionContext: executionContext)
            ]
        case .research:
            return [
                TavilySearchTool(executionContext: executionContext),
                AppleNotesTool(executionContext: executionContext),
                CurrentTimeTool(),
                ClarifyTool(executionContext: executionContext),
                TodoTool(executionContext: executionContext),
                ProfileMemoryTool(executionContext: executionContext),
                ReadFileTool(executionContext: executionContext),
                SearchFilesTool(executionContext: executionContext)
            ]
        case .planner:
            return [
                EventKitTool(executionContext: executionContext),
                ProposeCalendarEventsTool(executionContext: executionContext),
                CurrentTimeTool(),
                ClarifyTool(executionContext: executionContext),
                TodoTool(executionContext: executionContext),
                ProfileMemoryTool(executionContext: executionContext),
                AppleNotesTool(executionContext: executionContext)
            ]
        case .teach:
            return [
                TeachProgressTool(executionContext: executionContext),
                ProfileMemoryTool(executionContext: executionContext),
                ClarifyTool(executionContext: executionContext),
                AppleNotesTool(executionContext: executionContext),
                CurrentTimeTool()
            ]
        }
    }

    /// Tool names expected for each agent (for tests).
    static func toolNames(for agentType: AgentType) -> [String] {
        switch agentType {
        case .default:
            return [
                "run_terminal_command", "get_process_status", "list_directory", "read_file",
                "write_file", "patch", "search_files", "current_time", "clarify", "todo",
                "manage_calendar_and_reminders", "manage_apple_notes", "tavily_search",
                "send_imessage", "update_user_memory", "manage_mail"
            ]
        case .research:
            return [
                "tavily_search", "manage_apple_notes", "current_time", "clarify", "todo",
                "update_user_memory", "read_file", "search_files"
            ]
        case .planner:
            return [
                "manage_calendar_and_reminders", "propose_calendar_events", "current_time",
                "clarify", "todo", "update_user_memory", "manage_apple_notes"
            ]
        case .teach:
            return [
                "update_tutoring_progress", "update_user_memory", "clarify",
                "manage_apple_notes", "current_time"
            ]
        }
    }
}
