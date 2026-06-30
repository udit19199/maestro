//
//  SecurityPolicy.swift
//  zoro
//
//  Central security policy, validation, and escaping helpers.
//

import Foundation

enum AgentExecutionContext: Equatable {
    case local
    case iMessage(requester: String)
}

enum SecurityPolicy {
    static let maxFileReadBytes = 2_097_152
    static let maxShellOutputBytes = 524_288
    static let shellTimeoutSeconds: TimeInterval = 120
    static let maxIMessageAttachmentBytes = 1_048_576
    static let iMessageRateLimitPerMinute = 5
    static let maxIMessageReplyCharacters = 4_000

    static let gmailPageSize = 25
    static let maxGmailMessagesPerOperation = 100
    static let maxGmailBatchRead = 20
    static let maxGmailBodyBytes = 1_048_576
    static let gmailMaxRetries = 5

    private static let iMessageAllowedTools: Set<String> = [
        "list_directory",
        "read_file",
        "search_files",
        "current_time",
        "todo",
        "manage_calendar_and_reminders",
        "manage_apple_notes",
        "tavily_search",
        "send_imessage",
        "manage_gmail"
    ]

    private static let iMessageDeniedNoteActions: Set<String> = [
        "create_note",
        "append_note"
    ]

    private static let iMessageDeniedCalendarActions: Set<String> = [
        "delete_event"
    ]

    private static let iMessageDeniedGmailActions: Set<String> = [
        "send_email",
        "trash_message"
    ]

    static func contextDescription(_ context: AgentExecutionContext) -> String {
        switch context {
        case .local:
            return "local UI sessions"
        case .iMessage:
            return "iMessage remote sessions"
        }
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

    static func isGmailActionPermitted(_ action: String, context: AgentExecutionContext) -> Bool {
        switch context {
        case .local:
            return true
        case .iMessage:
            return !iMessageDeniedGmailActions.contains(action)
        }
    }

    static func isIMessageRecipientPermitted(_ recipient: String, context: AgentExecutionContext) -> Bool {
        switch context {
        case .local:
            return true
        case .iMessage(let requester):
            return normalizeContact(recipient) == normalizeContact(requester)
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

        return allowedSenders.contains(normalizedSender)
    }

    static func resolveWorkspacePath(_ path: String, relativeTo workspaceURL: URL) -> Result<URL, String> {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPath.contains("\0") {
            return .failure("Error: Invalid path.")
        }
        if trimmedPath.hasPrefix("/") || trimmedPath.hasPrefix("~") {
            return .failure("Error: Absolute paths are not allowed. Use a path relative to the workspace.")
        }

        let workspaceRoot = workspaceURL.standardizedFileURL
        let targetURL: URL
        if trimmedPath.isEmpty || trimmedPath == "." {
            targetURL = workspaceRoot
        } else {
            targetURL = workspaceRoot.appendingPathComponent(trimmedPath).standardizedFileURL
        }

        let rootPath = workspaceRoot.path
        let targetPath = targetURL.path
        let isInsideWorkspace = targetPath == rootPath || targetPath.hasPrefix(rootPath + "/")
        guard isInsideWorkspace else {
            return .failure("Error: Path escapes workspace boundary.")
        }

        return .success(targetURL)
    }

    static func resolveIMessageAttachmentPath(_ path: String) -> URL? {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let expandedPath = path.replacingOccurrences(of: "~", with: homePath)
        let attachmentURL = URL(fileURLWithPath: expandedPath).standardizedFileURL
        let attachmentsRoot = URL(
            fileURLWithPath: homePath.appending("/Library/Messages/Attachments")
        ).standardizedFileURL

        guard attachmentURL.path.hasPrefix(attachmentsRoot.path + "/") else {
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
