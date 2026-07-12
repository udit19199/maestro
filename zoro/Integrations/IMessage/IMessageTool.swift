//
//  IMessageTool.swift
//  zoro
//
//  LLM-facing tool stages messages for user confirmation.
//  App-controlled direct send is only for system replies (listener).
//

import Foundation
import FoundationModels

struct PendingIMessageSend: Identifiable, Equatable, Sendable {
    let id: UUID
    let recipient: String
    let text: String
    let service: String
    let conversationID: UUID?

    var preview: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 280 { return trimmed }
        return String(trimmed.prefix(280)) + "…"
    }
}

/// Direct AppleScript send — only for app-controlled paths (listener replies), never LLM free-fire.
enum IMessageDirectSender {
    @MainActor
    static func send(recipient: String, text: String, service: String = "auto") async throws {
        let escapedText = SecurityPolicy.escapeForAppleScript(text)
        let escapedRecipient = SecurityPolicy.escapeForAppleScript(recipient)
        let serviceType = service.lowercased()

        let script: String
        if serviceType == "imessage" {
            script = """
            tell application "Messages"
                set targetService to 1st service whose service type is iMessage
                set targetBuddy to buddy "\(escapedRecipient)" of targetService
                send "\(escapedText)" to targetBuddy
            end tell
            """
        } else if serviceType == "sms" {
            script = """
            tell application "Messages"
                set targetService to 1st service whose service type is SMS
                set targetBuddy to buddy "\(escapedRecipient)" of targetService
                send "\(escapedText)" to targetBuddy
            end tell
            """
        } else {
            script = """
            tell application "Messages"
                set targetBuddy to buddy "\(escapedRecipient)"
                send "\(escapedText)" to targetBuddy
            end tell
            """
        }

        try await runAppleScript(script)
    }

    private static func runAppleScript(_ script: String) async throws {
        let process = Process()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.arguments = ["-e", script]
        process.launchPath = "/usr/bin/osascript"

        try process.run()
        let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errStr = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "AppleScriptError",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: errStr]
            )
        }
    }
}

@MainActor
struct IMessageTool: Tool {
    let name = "send_imessage"
    let description = "Propose an iMessage/SMS to a recipient. Does NOT send until the user confirms in the Zoro app."
    let executionContext: AgentExecutionContext

    @Generable
    struct Arguments {
        @Guide(description: "The recipient's phone number (with country code, e.g. '+14155551212') or Apple ID email.")
        var recipient: String

        @Guide(description: "The text content of the message to send.")
        var text: String

        @Guide(description: "Optional. Service to use: 'imessage', 'sms', or 'auto' (default).")
        var service: String?
    }

    func call(arguments: Arguments) async throws -> String {
        if let permissionError = SecurityPolicy.toolPermissionError(for: name, context: executionContext) {
            return permissionError
        }

        let effectiveRecipient = SecurityPolicy.effectiveIMessageRecipient(
            requested: arguments.recipient,
            context: executionContext
        )

        guard SecurityPolicy.isIMessageRecipientPermitted(effectiveRecipient, context: executionContext) else {
            return "Error: Sending iMessage to '\(arguments.recipient)' is not permitted in \(SecurityPolicy.contextDescription(executionContext))."
        }

        let text = arguments.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return "Error: Message text is empty."
        }
        guard !effectiveRecipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Error: Recipient is empty."
        }

        let pending = PendingIMessageSend(
            id: UUID(),
            recipient: effectiveRecipient,
            text: text,
            service: arguments.service ?? "auto",
            conversationID: WorkspaceManager.shared.activeConversationID
        )
        WorkspaceManager.shared.setPendingIMessageSend(pending)

        return """
        iMessage staged — NOT sent. Waiting for user confirmation in Zoro.

        pending_imessage_id: \(pending.id.uuidString)
        to: \(effectiveRecipient)
        preview: \(pending.preview)

        Tell the user their message is ready and they must confirm send in Zoro before it goes out.
        """
    }
}
