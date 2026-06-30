//
//  IMessageTool.swift
//  zoro
//
//  Created by AI Agent on 22/06/26.
//

import Foundation
import FoundationModels

struct IMessageTool: Tool {
    let name = "send_imessage"
    let description = "Send a text message or iMessage to a recipient (phone number or Apple ID email)."

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
        let workspace = await WorkspaceManager.shared
        if let permissionError = await workspace.toolPermissionError(for: name) {
            return permissionError
        }

        let context = await workspace.currentExecutionContext
        guard SecurityPolicy.isIMessageRecipientPermitted(arguments.recipient, context: context) else {
            switch context {
            case .local:
                return "Error: Recipient is not permitted."
            case .iMessage(let requester):
                return "Error: iMessage remote sessions may only reply to the requester (\(requester))."
            }
        }

        let stepId = await workspace.addResearchStep("Sending iMessage to \(arguments.recipient)")

        let escapedText = SecurityPolicy.escapeForAppleScript(arguments.text)
        let escapedRecipient = SecurityPolicy.escapeForAppleScript(arguments.recipient)

        let serviceType = arguments.service?.lowercased() ?? "auto"
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

        do {
            _ = try await runAppleScript(script)
            await workspace.completeResearchStep(id: stepId)
            return "Message successfully sent to \(arguments.recipient)."
        } catch {
            await workspace.failResearchStep(id: stepId)
            return "Error sending iMessage: \(error.localizedDescription)"
        }
    }

    private func runAppleScript(_ script: String) async throws -> String {
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
            throw NSError(domain: "AppleScriptError", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errStr])
        }

        return String(data: data, encoding: .utf8) ?? ""
    }
}
