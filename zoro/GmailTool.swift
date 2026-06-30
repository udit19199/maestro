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
    Use read_attachment for text/PDF attachments. Never summarize email from snippets alone.
    """

    @Generable
    struct Arguments {
        @Guide(description: "Action: get_status, list_messages, search_messages, read_message, read_messages, read_thread, read_attachment, mark_read, archive_message, star_message, unstar_message, modify_labels, list_labels, create_draft, reply_to_thread, send_email, trash_message")
        var action: String

        @Guide(description: "Gmail message ID")
        var messageId: String?

        @Guide(description: "Gmail attachment ID from read_message output")
        var attachmentId: String?

        @Guide(description: "Gmail thread ID")
        var threadId: String?

        @Guide(description: "Message ID being replied to (reply_to_thread)")
        var inReplyToMessageId: String?

        @Guide(description: "Multiple message IDs (read_messages)")
        var messageIds: [String]?

        @Guide(description: "Gmail search query")
        var query: String?

        @Guide(description: "Label IDs for list_messages, e.g. ['INBOX']")
        var labelIds: [String]?

        @Guide(description: "Label IDs to add (modify_labels)")
        var addLabelIds: [String]?

        @Guide(description: "Label IDs to remove (modify_labels)")
        var removeLabelIds: [String]?

        @Guide(description: "Max results per page. Defaults to 25.")
        var maxResults: Int?

        @Guide(description: "Paginate until cap or no next page. Defaults to true.")
        var fetchAll: Bool?

        @Guide(description: "Page token when fetch_complete was false")
        var pageToken: String?

        @Guide(description: "Recipient email")
        var to: String?

        @Guide(description: "Email subject")
        var subject: String?

        @Guide(description: "Plain-text email body")
        var body: String?

        @Guide(description: "Optional CC, comma-separated")
        var cc: String?

        @Guide(description: "Optional BCC, comma-separated")
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
            var readIds: [String] = []
            var isIndexOnly = false

            switch arguments.action {
            case "get_status":
                let status = try await service.fetchStatus()
                await MainActor.run { GmailManager.shared.unreadCount = status.unreadInbox }
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
                result = try await service.listMessages(
                    labelIds: labels,
                    maxResults: arguments.maxResults,
                    fetchAll: arguments.fetchAll ?? true,
                    pageToken: arguments.pageToken
                ).formatted()
                isIndexOnly = true

            case "search_messages":
                guard let query = arguments.query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
                    await gmail.failActivity(matching: activityLabel)
                    return "Error: Missing required 'query' for 'search_messages'."
                }
                result = try await service.searchMessages(
                    query: query,
                    maxResults: arguments.maxResults,
                    fetchAll: arguments.fetchAll ?? true,
                    pageToken: arguments.pageToken
                ).formatted()
                isIndexOnly = true

            case "read_message":
                guard let messageId = arguments.messageId, !messageId.isEmpty else {
                    await gmail.failActivity(matching: activityLabel)
                    return "Error: Missing required 'messageId' for 'read_message'."
                }
                result = try await service.readMessage(id: messageId).formatted()
                readIds = [messageId]

            case "read_messages":
                let ids = arguments.messageIds ?? []
                guard !ids.isEmpty else {
                    await gmail.failActivity(matching: activityLabel)
                    return "Error: Missing required 'messageIds' for 'read_messages'."
                }
                result = try await service.readMessages(ids: ids).formatted()
                readIds = ids

            case "read_thread":
                guard let threadId = arguments.threadId, !threadId.isEmpty else {
                    await gmail.failActivity(matching: activityLabel)
                    return "Error: Missing required 'threadId' for 'read_thread'."
                }
                result = try await service.readThread(threadId: threadId).formatted()
                readIds = GmailParsing.extractMessageIds(from: result)

            case "read_attachment":
                guard let messageId = arguments.messageId, !messageId.isEmpty,
                      let attachmentId = arguments.attachmentId, !attachmentId.isEmpty else {
                    await gmail.failActivity(matching: activityLabel)
                    return "Error: Missing required 'messageId' and 'attachmentId' for 'read_attachment'."
                }
                result = try await service.readAttachment(messageId: messageId, attachmentId: attachmentId).formatted()
                readIds = [messageId]

            case "mark_read":
                guard let messageId = arguments.messageId, !messageId.isEmpty else {
                    await gmail.failActivity(matching: activityLabel)
                    return "Error: Missing required 'messageId' for 'mark_read'."
                }
                result = try await service.markMessageAsRead(id: messageId)

            case "archive_message":
                guard let messageId = arguments.messageId, !messageId.isEmpty else {
                    await gmail.failActivity(matching: activityLabel)
                    return "Error: Missing required 'messageId' for 'archive_message'."
                }
                result = try await service.archiveMessage(id: messageId)

            case "star_message":
                guard let messageId = arguments.messageId, !messageId.isEmpty else {
                    await gmail.failActivity(matching: activityLabel)
                    return "Error: Missing required 'messageId' for 'star_message'."
                }
                result = try await service.starMessage(id: messageId)

            case "unstar_message":
                guard let messageId = arguments.messageId, !messageId.isEmpty else {
                    await gmail.failActivity(matching: activityLabel)
                    return "Error: Missing required 'messageId' for 'unstar_message'."
                }
                result = try await service.unstarMessage(id: messageId)

            case "modify_labels":
                guard let messageId = arguments.messageId, !messageId.isEmpty else {
                    await gmail.failActivity(matching: activityLabel)
                    return "Error: Missing required 'messageId' for 'modify_labels'."
                }
                result = try await service.modifyMessageLabels(
                    id: messageId,
                    add: arguments.addLabelIds ?? [],
                    remove: arguments.removeLabelIds ?? []
                )

            case "list_labels":
                result = try await service.listLabels()

            case "create_draft":
                guard let to = arguments.to, !to.isEmpty,
                      let subject = arguments.subject,
                      let body = arguments.body else {
                    await gmail.failActivity(matching: activityLabel)
                    return "Error: Missing required fields ('to', 'subject', 'body') for 'create_draft'."
                }
                result = try await service.createDraft(
                    to: to,
                    subject: subject,
                    body: body,
                    cc: arguments.cc,
                    bcc: arguments.bcc,
                    threadId: arguments.threadId
                )

            case "reply_to_thread":
                guard let threadId = arguments.threadId, !threadId.isEmpty,
                      let inReplyTo = arguments.inReplyToMessageId, !inReplyTo.isEmpty,
                      let to = arguments.to, !to.isEmpty,
                      let subject = arguments.subject,
                      let body = arguments.body else {
                    await gmail.failActivity(matching: activityLabel)
                    return "Error: Missing required fields for 'reply_to_thread' (threadId, inReplyToMessageId, to, subject, body)."
                }
                result = try await service.replyToThread(
                    threadId: threadId,
                    inReplyToMessageId: inReplyTo,
                    to: to,
                    subject: subject,
                    body: body
                )

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
            return await finalize(result, readIds: readIds, isIndexOnly: isIndexOnly)
        } catch {
            await gmail.failActivity(matching: activityLabel)
            return "Error: \(error.localizedDescription)"
        }
    }

    private func finalize(_ result: String, readIds: [String], isIndexOnly: Bool) async -> String {
        await MainActor.run {
            if isIndexOnly {
                GmailReadAuditor.recordIndexFetch(output: result)
            }
            if !readIds.isEmpty {
                GmailManager.shared.recordMessagesRead(readIds)
                GmailReadAuditor.recordFullRead()
            }
        }
        let footer = await GmailManager.shared.sessionReadFooter()
        return result + "\n\n" + footer
    }
}
