//
//  SecurityPolicy.swift
//  zoro
//
//  Central security policy, validation, and escaping helpers.
//  Authorization is enforced in Swift — not via system prompts.
//

import Foundation

enum AgentExecutionContext: Equatable, Sendable {
    case local
    case iMessage(requester: String)

    var isRemote: Bool {
        if case .iMessage = self { return true }
        return false
    }

    var requester: String? {
        if case .iMessage(let requester) = self { return requester }
        return nil
    }
}

struct WorkspacePathResolutionError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

enum SecurityPolicy {
    static let maxFileReadBytes = 2_097_152
    static let maxShellOutputBytes = 524_288
    static let shellTimeoutSeconds: TimeInterval = 120
    static let maxIMessageAttachmentBytes = 1_048_576
    static let iMessageRateLimitPerMinute = 5
    static let maxIMessageReplyCharacters = 4_000

    static let gmailPageSize = 25
    static let maxGmailMessagesPerOperation = 250
    static let maxGmailBatchRead = 20
    static let maxGmailBodyBytes = 1_048_576
    static let gmailMaxRetries = 5
    static let gmailAutoRefreshSeconds: TimeInterval = 300

    /// Tools the model may invoke during an iMessage-sourced turn.
    /// Outbound side effects (send text/email, calendar create, memory write) are denied
    /// or require on-Mac user confirmation — never free-fire from remote.
    private static let iMessageAllowedTools: Set<String> = [
        "list_directory",
        "read_file",
        "search_files",
        "current_time",
        "todo",
        "manage_calendar_and_reminders",
        "manage_apple_notes",
        "tavily_search",
        "manage_mail"
        // send_imessage intentionally omitted: remote replies use app-controlled direct send only
        // update_user_memory intentionally omitted
        // run_terminal_command / write_file / patch intentionally omitted
    ]

    private static let iMessageDeniedMailActions: Set<String> = [
        "send_email",
        "reply_to_message",
        "create_draft",
        "archive_message",
        "mark_read"
    ]

    private static let iMessageDeniedNoteActions: Set<String> = [
        "create_note",
        "append_note"
    ]

    /// Remote calendar: read-only. Creates/deletes require local UI confirm paths.
    private static let iMessageDeniedCalendarActions: Set<String> = [
        "create_event",
        "delete_event",
        "create_reminder",
        "complete_reminder"
    ]

    static func contextDescription(_ context: AgentExecutionContext) -> String {
        switch context {
        case .local:
            return "local UI sessions"
        case .iMessage:
            return "iMessage remote sessions"
        }
    }

    static func toolPermissionError(for toolName: String, context: AgentExecutionContext) -> String? {
        guard isToolPermitted(toolName, context: context) else {
            return "Error: Tool '\(toolName)' is not permitted in \(contextDescription(context))."
        }
        return nil
    }

    static func isToolPermitted(_ toolName: String, context: AgentExecutionContext) -> Bool {
        switch context {
        case .local:
            return true
        case .iMessage:
            return iMessageAllowedTools.contains(toolName)
        }
    }

    static func isNotesActionPermitted(_ action: String, context: AgentExecutionContext) -> Bool {
        switch context {
        case .local:
            return true
        case .iMessage:
            return !iMessageDeniedNoteActions.contains(action)
        }
    }

    static func isCalendarActionPermitted(_ action: String, context: AgentExecutionContext) -> Bool {
        switch context {
        case .local:
            return true
        case .iMessage:
            return !iMessageDeniedCalendarActions.contains(action)
        }
    }

    static func isMailActionPermitted(_ action: String, context: AgentExecutionContext) -> Bool {
        switch context {
        case .local:
            return true
        case .iMessage:
            return !iMessageDeniedMailActions.contains(action)
        }
    }

    /// Remote: only the stored requester. Local: any recipient (still requires user confirm to send).
    static func isIMessageRecipientPermitted(_ recipient: String, context: AgentExecutionContext) -> Bool {
        switch context {
        case .local:
            return true
        case .iMessage(let requester):
            return normalizeContact(recipient) == normalizeContact(requester)
        }
    }

    /// Effective recipient for LLM send_imessage: remote always forces stored requester.
    static func effectiveIMessageRecipient(requested: String, context: AgentExecutionContext) -> String {
        switch context {
        case .local:
            return requested
        case .iMessage(let requester):
            return requester
        }
    }

    static func normalizeContact(_ contact: String) -> String {
        var normalized = contact
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        normalized = normalized.replacingOccurrences(of: " ", with: "")
        normalized = normalized.replacingOccurrences(of: "-", with: "")
        normalized = normalized.replacingOccurrences(of: "(", with: "")
        normalized = normalized.replacingOccurrences(of: ")", with: "")
        if normalized.hasPrefix("+") {
            normalized.removeFirst()
        }
        return normalized
    }

    static func isSenderWhitelisted(_ sender: String, whitelist: String) -> Bool {
        let normalizedSender = normalizeContact(sender)
        guard !normalizedSender.isEmpty else { return false }

        let allowedSenders = whitelist
            .components(separatedBy: ",")
            .map { normalizeContact($0) }
            .filter { !$0.isEmpty }

        guard !allowedSenders.isEmpty else { return false }
        return allowedSenders.contains(normalizedSender)
    }

    static func hasNonEmptyWhitelist(_ whitelist: String) -> Bool {
        whitelist
            .components(separatedBy: ",")
            .map { normalizeContact($0) }
            .contains { !$0.isEmpty }
    }

    // MARK: - Workspace paths (symlink-safe)

    /// Resolves a workspace-relative path. Follows symlinks for existing paths;
    /// for non-existent paths (writes), validates each existing prefix component.
    static func resolveWorkspacePath(_ path: String, relativeTo workspaceURL: URL) -> Result<URL, WorkspacePathResolutionError> {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPath.contains("\0") {
            return .failure(WorkspacePathResolutionError(message: "Error: Invalid path."))
        }
        if trimmedPath.hasPrefix("/") || trimmedPath.hasPrefix("~") {
            return .failure(WorkspacePathResolutionError(message: "Error: Absolute paths are not allowed. Use a path relative to the workspace."))
        }

        let fileManager = FileManager.default
        let workspaceRoot = workspaceURL.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = workspaceRoot.path

        let relativeComponents: [String]
        if trimmedPath.isEmpty || trimmedPath == "." {
            relativeComponents = []
        } else {
            relativeComponents = trimmedPath
                .split(separator: "/")
                .map(String.init)
                .filter { $0 != "." && !$0.isEmpty }
        }

        if relativeComponents.contains("..") {
            // Still allow ".." only if final resolved path stays inside after realpath
        }

        var accumulated = workspaceRoot
        for (index, component) in relativeComponents.enumerated() {
            if component == ".." {
                accumulated = accumulated.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            } else {
                accumulated = accumulated.appendingPathComponent(component)
            }

            let isLast = index == relativeComponents.count - 1
            if fileManager.fileExists(atPath: accumulated.path) {
                accumulated = accumulated.resolvingSymlinksInPath().standardizedFileURL
            } else if !isLast {
                return .failure(WorkspacePathResolutionError(message: "Error: Path escapes workspace boundary or intermediate component is missing."))
            }

            let currentPath = accumulated.path
            let inside = currentPath == rootPath || currentPath.hasPrefix(rootPath + "/")
            guard inside else {
                return .failure(WorkspacePathResolutionError(message: "Error: Path escapes workspace boundary."))
            }
        }

        if relativeComponents.isEmpty {
            return .success(workspaceRoot)
        }

        let finalPath = accumulated.path
        let inside = finalPath == rootPath || finalPath.hasPrefix(rootPath + "/")
        guard inside else {
            return .failure(WorkspacePathResolutionError(message: "Error: Path escapes workspace boundary."))
        }

        // Parent of a new file must resolve inside workspace
        if !fileManager.fileExists(atPath: accumulated.path) {
            let parent = accumulated.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            let parentPath = parent.path
            let parentInside = parentPath == rootPath || parentPath.hasPrefix(rootPath + "/")
            guard parentInside else {
                return .failure(WorkspacePathResolutionError(message: "Error: Path escapes workspace boundary."))
            }
        }

        return .success(accumulated)
    }

    static func resolveIMessageAttachmentPath(_ path: String) -> URL? {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let expandedPath = path.replacingOccurrences(of: "~", with: homePath)
        let attachmentURL = URL(fileURLWithPath: expandedPath).resolvingSymlinksInPath().standardizedFileURL
        let attachmentsRoot = URL(
            fileURLWithPath: homePath.appending("/Library/Messages/Attachments")
        ).resolvingSymlinksInPath().standardizedFileURL

        let attachPath = attachmentURL.path
        let rootPath = attachmentsRoot.path
        guard attachPath == rootPath || attachPath.hasPrefix(rootPath + "/") else {
            return nil
        }
        return attachmentURL
    }

    static func truncateOutput(_ output: String, maxBytes: Int, suffix: String) -> String {
        guard output.utf8.count > maxBytes else { return output }
        var truncated = output
        while truncated.utf8.count > maxBytes && !truncated.isEmpty {
            truncated.removeLast()
        }
        return truncated + suffix
    }

    static func escapeForAppleScript(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.count)

        for character in text {
            switch character {
            case "\\":
                escaped += "\\\\"
            case "\"":
                escaped += "\\\""
            case "\n":
                escaped += "\\n"
            case "\r":
                escaped += "\\r"
            case "\t":
                escaped += "\\t"
            default:
                if character.unicodeScalars.allSatisfy({ !$0.isASCII || ($0.value >= 32 && $0.value != 127) }) {
                    escaped.append(character)
                }
            }
        }

        return escaped
    }

    static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
