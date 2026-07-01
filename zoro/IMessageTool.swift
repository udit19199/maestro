//
//  IMessageTool.swift
//  zoro
//
//  Created by AI Agent on 22/06/26.
//

import Foundation
import FoundationModels

@MainActor
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
        let stepId: UUID?
        if await !WorkspaceManager.shared.isIMessageContext {
            stepId = await WorkspaceManager.shared.addResearchStep("Sending iMessage to \(arguments.recipient)")
        } else {
            stepId = nil
        }
        
        let escapedText = escapeForAppleScript(arguments.text)
        let escapedRecipient = escapeForAppleScript(arguments.recipient)
        
        let serviceType = arguments.service?.lowercased() ?? "auto"
        var script = ""
        
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
            // Auto-detect service or let Messages.app decide
            script = """
            tell application "Messages"
                set targetBuddy to buddy "\(escapedRecipient)"
                send "\(escapedText)" to targetBuddy
            end tell
            """
        }
        
        do {
            _ = try await runAppleScript(script)
            if let stepId {
                await WorkspaceManager.shared.completeResearchStep(id: stepId)
            }
            return "Message successfully sent to \(arguments.recipient)."
        } catch {
            if let stepId {
                await WorkspaceManager.shared.failResearchStep(id: stepId)
            }
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
            let errData = try? pipe.fileHandleForReading.readToEnd()
            let errStr = errData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            throw NSError(domain: "AppleScriptError", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errStr])
        }
        
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func escapeForAppleScript(_ text: String) -> String {
        var escaped = text
        escaped = escaped.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        return escaped
    }
}
