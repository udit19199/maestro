//
//  GmailTool.swift
//  zoro
//
//  Gmail tool with complete-fetch guarantees and anti-hallucination structured output.
//

import Foundation
import FoundationModels

struct GmailTool: Tool {
    let name = "manage_gmail"
    let description = """
    First-class Gmail integration. Always returns a structured GMAIL FETCH REPORT with fetch_complete flags.
    Use get_status for account/unread info. Use search/list for indexes, then read_message/read_messages/read_thread for full bodies.
    Never summarize email from snippets alone.
    """

    @Generable
    struct Arguments {
        @Guide(description: "Action: 'get_status', 'list_messages', 'search_messages', 'read_message', 'read_messages', 'read_thread', 'send_email', 'trash_message'")
        var action: String

        @Guide(description: "Gmail message ID (read_message, trash_message)")
        var messageId: String?

        @Guide(description: "Gmail thread ID (read_thread)")
        var threadId: String?

        @Guide(description: "Multiple message IDs to read in one call (read_messages)")
        var messageIds: [String]?

        @Guide(description: "Gmail search query (search_messages), e.g. 'from:alice is:unread newer_than:7d'")
        var query: String?

        @Guide(description: "Label IDs for list_messages, e.g. ['INBOX']. Defaults to INBOX.")
        var labelIds: [String]?

        @Guide(description: "Max results per page. Defaults to 25.")
        var maxResults: Int?

        @Guide(description: "When true, paginate until all matches are fetched (up to app limit) or no next page. Defaults to true for thoroughness.")
        var fetchAll: Bool?

        @Guide(description: "Page token from a previous fetch report when fetch_complete was false.")
        var pageToken: String?

        @Guide(description: "Recipient email (send_email)")
        var to: String?

        @Guide(description: "Email subject (send_email)")
        var subject: String?

        @Guide(description: "Plain-text email body (send_email)")
        var body: String?

        @Guide(description: "Optional CC, comma-separated (send_email)")
        var cc: String?

        @Guide(description: "Optional BCC, comma-separated (send_email)")
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

        let gmail = await GmailManager.shared
        let activityLabel = "Gmail: \(arguments.action)"

        let service: GmailService
        do {
            service = try await GmailService.makeAuthenticated()
        } catch {
            return "Error: \(error.localizedDescription)"
        }

        await gmail.logActivity(activityLabel)

        do {
            let result: String
            switch arguments.action {
            case "get_status":
                let status = try await service.fetchStatus()
                await gmail.completeActivity(matching: activityLabel)
                await MainActor.run {
                    GmailManager.shared.unreadCount = status.unreadInbox
                }
                result = """
                === GMAIL FETCH REPORT ===
                action: get_status
                fetch_complete: true
                === END REPORT ===

                email: \(status.emailAddress)
                messages_total: \(status.messagesTotal)
                threads_total: \(status.threadsTotal)
                unread_inbox: \(status.unreadInbox)
                history_id: \(status.historyId)
                """

            case "list_messages":
                let labels = arguments.labelIds ?? ["INBOX"]
                let fetchAll = arguments.fetchAll ?? true
                let report = try await service.listMessages(
                    labelIds: labels,
                    maxResults: arguments.maxResults,
                    fetchAll: fetchAll,
                    pageToken: arguments.pageToken
                )
                result = report.formatted()

            case "search_messages":
                guard let query = arguments.query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
                    await gmail.failActivity(matching: activityLabel)
                    return "Error: Missing required 'query' for 'search_messages'."
                }
                let fetchAll = arguments.fetchAll ?? true
                let report = try await service.searchMessages(
                    query: query,
                    maxResults: arguments.maxResults,
                    fetchAll: fetchAll,
                    pageToken: arguments.pageToken
                )
                result = report.formatted()

            case "read_message":
                guard let messageId = arguments.messageId, !messageId.isEmpty else {
                    await gmail.failActivity(matching: activityLabel)
                    return "Error: Missing required 'messageId' for 'read_message'."
                }
                result = try await service.readMessage(id: messageId).formatted()

            case "read_messages":
                let ids = arguments.messageIds ?? []
                guard !ids.isEmpty else {
                    await gmail.failActivity(matching: activityLabel)
                    return "Error: Missing required 'messageIds' for 'read_messages'."
                }
                result = try await service.readMessages(ids: ids).formatted()

            case "read_thread":
                guard let threadId = arguments.threadId, !threadId.isEmpty else {
                    await gmail.failActivity(matching: activityLabel)
                    return "Error: Missing required 'threadId' for 'read_thread'."
                }
                result = try await service.readThread(threadId: threadId).formatted()

            case "send_email":
                guard let to = arguments.to, !to.isEmpty,
                      let subject = arguments.subject,
                      let body = arguments.body else {
                    await gmail.failActivity(matching: activityLabel)
                    return "Error: Missing required fields ('to', 'subject', 'body') for 'send_email'."
                }
                result = try await service.sendEmail(to: to, subject: subject, body: body, cc: arguments.cc, bcc: arguments.bcc)

            case "trash_message":
                guard let messageId = arguments.messageId, !messageId.isEmpty else {
                    await gmail.failActivity(matching: activityLabel)
                    return "Error: Missing required 'messageId' for 'trash_message'."
                }
                result = try await service.trashMessage(id: messageId)

            default:
                await gmail.failActivity(matching: activityLabel)
                return "Error: Invalid action '\(arguments.action)'."
            }

            await gmail.completeActivity(matching: activityLabel)
            Task { await gmail.refreshSnapshot() }
            return result
        } catch {
            await gmail.failActivity(matching: activityLabel)
            return "Error: \(error.localizedDescription)"
        }
    }
}
