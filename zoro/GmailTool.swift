//
//  GmailTool.swift
//  zoro
//
//  Gmail API integration for reading, searching, sending, and managing email.
//

import Foundation
import FoundationModels

struct GmailTool: Tool {
    let name = "manage_gmail"
    let description = "Read, search, send, and manage Gmail messages. Requires Gmail to be connected in Zoro Settings."

    @Generable
    struct Arguments {
        @Guide(description: "The action to perform: 'list_messages', 'search_messages', 'read_message', 'send_email', 'trash_message'")
        var action: String

        @Guide(description: "Gmail message ID (for read_message and trash_message)")
        var messageId: String?

        @Guide(description: "Gmail search query (for search_messages). Supports Gmail search syntax, e.g. 'from:alice subject:invoice is:unread'")
        var query: String?

        @Guide(description: "Gmail label IDs to filter by (for list_messages), e.g. 'INBOX', 'SENT', 'STARRED'. Defaults to INBOX.")
        var labelIds: [String]?

        @Guide(description: "Maximum number of messages to return. Defaults to 10.")
        var maxResults: Int?

        @Guide(description: "Recipient email address (for send_email)")
        var to: String?

        @Guide(description: "Email subject (for send_email)")
        var subject: String?

        @Guide(description: "Email body in plain text (for send_email)")
        var body: String?

        @Guide(description: "Optional CC recipients, comma-separated (for send_email)")
        var cc: String?

        @Guide(description: "Optional BCC recipients, comma-separated (for send_email)")
        var bcc: String?
    }

    func call(arguments: Arguments) async throws -> String {
        let workspace = await WorkspaceManager.shared
        if let permissionError = await workspace.toolPermissionError(for: name) {
            return permissionError
        }

        let context = await workspace.currentExecutionContext
        guard SecurityPolicy.isGmailActionPermitted(arguments.action, context: context) else {
            return "Error: Gmail action '\(arguments.action)' is not permitted in \(SecurityPolicy.contextDescription(context))."
        }

        let client: GmailAPIClient
        do {
            client = try await GmailAPIClient.makeAuthenticated()
        } catch {
            return "Error: \(error.localizedDescription)"
        }

        switch arguments.action {
        case "list_messages":
            let labels = arguments.labelIds ?? ["INBOX"]
            let maxResults = min(arguments.maxResults ?? 10, 25)
            let stepId = await workspace.addResearchStep("Listing Gmail messages (\(labels.joined(separator: ", ")))")
            do {
                let result = try await client.listMessages(labelIds: labels, maxResults: maxResults)
                await workspace.completeResearchStep(id: stepId)
                return result
            } catch {
                await workspace.failResearchStep(id: stepId)
                return "Error: \(error.localizedDescription)"
            }

        case "search_messages":
            guard let query = arguments.query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "Error: Missing required 'query' for 'search_messages'."
            }
            let maxResults = min(arguments.maxResults ?? 10, 25)
            let stepId = await workspace.addResearchStep("Searching Gmail: \(query)")
            do {
                let result = try await client.searchMessages(query: query, maxResults: maxResults)
                await workspace.completeResearchStep(id: stepId)
                return result
            } catch {
                await workspace.failResearchStep(id: stepId)
                return "Error: \(error.localizedDescription)"
            }

        case "read_message":
            guard let messageId = arguments.messageId, !messageId.isEmpty else {
                return "Error: Missing required 'messageId' for 'read_message'."
            }
            let stepId = await workspace.addResearchStep("Reading Gmail message \(messageId)")
            do {
                let result = try await client.readMessage(id: messageId)
                await workspace.completeResearchStep(id: stepId)
                return result
            } catch {
                await workspace.failResearchStep(id: stepId)
                return "Error: \(error.localizedDescription)"
            }

        case "send_email":
            guard let to = arguments.to, !to.isEmpty,
                  let subject = arguments.subject,
                  let body = arguments.body else {
                return "Error: Missing required fields ('to', 'subject', 'body') for 'send_email'."
            }
            let stepId = await workspace.addResearchStep("Sending email to \(to)")
            do {
                let result = try await client.sendEmail(
                    to: to,
                    subject: subject,
                    body: body,
                    cc: arguments.cc,
                    bcc: arguments.bcc
                )
                await workspace.completeResearchStep(id: stepId)
                return result
            } catch {
                await workspace.failResearchStep(id: stepId)
                return "Error: \(error.localizedDescription)"
            }

        case "trash_message":
            guard let messageId = arguments.messageId, !messageId.isEmpty else {
                return "Error: Missing required 'messageId' for 'trash_message'."
            }
            do {
                return try await client.trashMessage(id: messageId)
            } catch {
                return "Error: \(error.localizedDescription)"
            }

        default:
            return "Error: Invalid action '\(arguments.action)'."
        }
    }
}

// MARK: - Gmail API Client

struct GmailAPIClient {
    let accessToken: String

    static func makeAuthenticated() async throws -> GmailAPIClient {
        let token = try await GmailAuthManager.shared.getValidAccessToken()
        return GmailAPIClient(accessToken: token)
    }

    func listMessages(labelIds: [String], maxResults: Int) async throws -> String {
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        var queryItems = [URLQueryItem(name: "maxResults", value: String(maxResults))]
        for label in labelIds {
            queryItems.append(URLQueryItem(name: "labelIds", value: label))
        }
        components.queryItems = queryItems
        let list = try await decode(GmailMessageList.self, from: components.url!)
        return try await formatMessageSummaries(list.messages ?? [], emptyMessage: "No messages found in \(labelIds.joined(separator: ", ")).")
    }

    func searchMessages(query: String, maxResults: Int) async throws -> String {
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: String(maxResults))
        ]
        let list = try await decode(GmailMessageList.self, from: components.url!)
        return try await formatMessageSummaries(list.messages ?? [], emptyMessage: "No messages matched query: \(query)")
    }

    func readMessage(id: String) async throws -> String {
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)")!
        components.queryItems = [URLQueryItem(name: "format", value: "full")]
        let message = try await decode(GmailMessageDetail.self, from: components.url!)

        let headers = Dictionary(uniqueKeysWithValues: (message.payload?.headers ?? []).map { ($0.name.lowercased(), $0.value) })
        let from = headers["from"] ?? "Unknown"
        let to = headers["to"] ?? "Unknown"
        let subject = headers["subject"] ?? "(No subject)"
        let date = headers["date"] ?? "Unknown"
        let body = extractBody(from: message.payload)
        let truncatedBody = SecurityPolicy.truncateOutput(
            body,
            maxBytes: SecurityPolicy.maxFileReadBytes,
            suffix: "\n\n[Message body truncated at \(SecurityPolicy.maxFileReadBytes) bytes]"
        )

        var lines = [
            "Message ID: \(message.id)",
            "Thread ID: \(message.threadId)",
            "From: \(from)",
            "To: \(to)",
            "Date: \(date)",
            "Subject: \(subject)",
            "Labels: \((message.labelIds ?? []).joined(separator: ", "))",
            "",
            "--- Body ---",
            truncatedBody.isEmpty ? "(Empty body)" : truncatedBody
        ]
        return lines.joined(separator: "\n")
    }

    func sendEmail(to: String, subject: String, body: String, cc: String?, bcc: String?) async throws -> String {
        let rawMessage = buildRawEmail(to: to, subject: subject, body: body, cc: cc, bcc: bcc)
        let encoded = Data(rawMessage.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["raw": encoded])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw GmailAuthError.networkError("Send failed: \(detail)")
        }

        if let sent = try? JSONDecoder().decode(GmailSendResponse.self, from: data) {
            return "Successfully sent email to \(to). Message ID: \(sent.id)"
        }
        return "Successfully sent email to \(to)."
    }

    func trashMessage(id: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)/trash")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw GmailAuthError.networkError("Trash failed: \(detail)")
        }
        return "Successfully moved message \(id) to trash."
    }

    private func formatMessageSummaries(_ refs: [GmailMessageRef], emptyMessage: String) async throws -> String {
        guard !refs.isEmpty else { return emptyMessage }

        var lines = ["Gmail messages found:"]
        for ref in refs {
            var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(ref.id)")!
            var queryItems = [URLQueryItem(name: "format", value: "metadata")]
            for header in ["From", "Subject", "Date"] {
                queryItems.append(URLQueryItem(name: "metadataHeaders", value: header))
            }
            components.queryItems = queryItems
            let detail = try await decode(GmailMessageDetail.self, from: components.url!)
            let headers = Dictionary(uniqueKeysWithValues: (detail.payload?.headers ?? []).map { ($0.name.lowercased(), $0.value) })
            let from = headers["from"] ?? "Unknown"
            let subject = headers["subject"] ?? "(No subject)"
            let date = headers["date"] ?? "Unknown"
            let snippet = detail.snippet ?? ""
            lines.append("- [\(ref.id)] \(subject) — from \(from) (\(date))\n  Snippet: \(snippet)")
        }
        return lines.joined(separator: "\n")
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw GmailAuthError.networkError(detail)
        }
        return try JSONDecoder().decode(type, from: data)
    }

    private func buildRawEmail(to: String, subject: String, body: String, cc: String?, bcc: String?) -> String {
        var lines = [
            "To: \(to)",
            "Subject: \(subject)",
            "Content-Type: text/plain; charset=utf-8",
            "MIME-Version: 1.0"
        ]
        if let cc, !cc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.insert("Cc: \(cc)", at: 1)
        }
        if let bcc, !bcc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.insert("Bcc: \(bcc)", at: 1)
        }
        lines.append("")
        lines.append(body)
        return lines.joined(separator: "\r\n")
    }

    private func extractBody(from payload: GmailMessagePayload?) -> String {
        guard let payload else { return "" }

        if let data = payload.body?.data, let text = decodeBase64URL(data) {
            return text
        }

        if let parts = payload.parts {
            for part in parts {
                if part.mimeType == "text/plain", let data = part.body?.data, let text = decodeBase64URL(data) {
                    return text
                }
            }
            for part in parts {
                if part.mimeType == "text/html", let data = part.body?.data, let text = decodeBase64URL(data) {
                    return stripHTML(text)
                }
            }
            for part in parts {
                let nested = extractBody(from: part)
                if !nested.isEmpty { return nested }
            }
        }

        return ""
    }

    private func decodeBase64URL(_ input: String) -> String? {
        var base64 = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = 4 - (base64.count % 4)
        if padding < 4 {
            base64 += String(repeating: "=", count: padding)
        }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func stripHTML(_ html: String) -> String {
        html
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct GmailMessageList: Decodable {
    let messages: [GmailMessageRef]?
}

private struct GmailMessageRef: Decodable {
    let id: String
}

private struct GmailMessageDetail: Decodable {
    let id: String
    let threadId: String
    let labelIds: [String]?
    let snippet: String?
    let payload: GmailMessagePayload?
}

private struct GmailMessagePayload: Decodable {
    let mimeType: String?
    let headers: [GmailHeader]?
    let body: GmailMessageBody?
    let parts: [GmailMessagePayload]?
}

private struct GmailHeader: Decodable {
    let name: String
    let value: String
}

private struct GmailMessageBody: Decodable {
    let data: String?
}

private struct GmailSendResponse: Decodable {
    let id: String
}
