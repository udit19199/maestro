//
//  MailTool.swift
//  zoro
//
//  Unified manage_mail tool for multi-account Gmail + IMAP.
//

import Foundation
import FoundationModels

struct PendingMailSendRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let accountId: UUID
    let accountLabel: String
    let draftId: String
    let to: String
    let subject: String
    let bodyPreview: String

    var panelModel: PendingMailSend {
        PendingMailSend(
            id: id,
            accountLabel: accountLabel,
            to: to,
            subject: subject,
            bodyPreview: bodyPreview
        )
    }
}

@MainActor
struct MailTool: Tool {
    let name = "manage_mail"
    let description = """
    Unified multi-inbox mail integration (Gmail + IMAP). Always returns structured MAIL FETCH REPORT blocks.
    Use get_status for account/unread info. Use list_unread/search for indexes, then read_message for full bodies.
    Never summarize email from snippets alone. send_email and reply_to_message create drafts only and return pending_send_id for user confirmation.
    """

    @Generable
    struct Arguments {
        @Guide(description: "Action: get_status, list_unread, search, read_message, archive_message, mark_read, create_draft, send_email, reply_to_message")
        var action: String

        @Guide(description: "Mail account UUID (optional for reads when one account; required for writes with multiple accounts)")
        var accountId: String?

        @Guide(description: "Mail account email address (alternative to account_id)")
        var accountEmail: String?

        @Guide(description: "Message ID from list_unread or search output")
        var messageId: String?

        @Guide(description: "Search query (provider-specific)")
        var query: String?

        @Guide(description: "Max results. Defaults to 25.")
        var maxResults: Int?

        @Guide(description: "Recipient email (create_draft, send_email, reply_to_message)")
        var to: String?

        @Guide(description: "Email subject")
        var subject: String?

        @Guide(description: "Plain-text email body")
        var body: String?

        @Guide(description: "Message ID being replied to (reply_to_message)")
        var inReplyToMessageId: String?

        @Guide(description: "Thread ID for replies when known")
        var threadId: String?
    }

    func call(arguments: Arguments) async throws -> String {
        let workspace = await WorkspaceManager.shared
        if let permissionError = await workspace.toolPermissionError(for: name) {
            return permissionError
        }

        let context = await workspace.currentExecutionContext
        guard SecurityPolicy.isMailActionPermitted(arguments.action, context: context) else {
            return "Error: Mail action '\(arguments.action)' is not permitted in \(SecurityPolicy.contextDescription(context))."
        }

        let mail = await MailManager.shared
        let activityLabel = "Mail: \(arguments.action)"
        await mail.logActivity(activityLabel)

        do {
            let result: String
            var readAccountId: UUID?
            var readMessageIds: [String] = []
            var isIndexOnly = false

            switch arguments.action {
            case "get_status":
                await mail.refreshSnapshot()
                let accounts = mail.configuredAccounts()
                let pairs = accounts.map { ($0, mail.syncStatus[$0.id]) }
                result = MailFormatting.formatStatus(accounts: pairs, totalUnread: mail.inboxUnreadTotal)

            case "list_unread":
                let limit = arguments.maxResults ?? SecurityPolicy.gmailPageSize
                if case .success(let pair) = mail.resolveProvider(
                    accountId: arguments.accountId,
                    accountEmail: arguments.accountEmail,
                    requireAccount: false
                ) {
                    let fetch = try await MailSyncActor.shared.fetchUnread(from: pair.0, limit: limit)
                    result = MailFormatting.formatIndex(fetch, account: pair.1)
                } else {
                    let providers = mail.allProviders()
                    guard !providers.isEmpty else {
                        await mail.failActivity(matching: activityLabel)
                        return "Error: No mail accounts connected."
                    }
                    if providers.count > 1 && arguments.accountId == nil && arguments.accountEmail == nil {
                        var merged: [(MailFetchResult, MailAccount)] = []
                        for pair in providers {
                            let fetch = try await MailSyncActor.shared.fetchUnread(from: pair.provider, limit: limit)
                            merged.append((fetch, pair.account))
                        }
                        result = MailFormatting.formatMergedIndex(results: merged)
                    } else if let pair = providers.first {
                        let fetch = try await MailSyncActor.shared.fetchUnread(from: pair.provider, limit: limit)
                        result = MailFormatting.formatIndex(fetch, account: pair.account)
                    } else {
                        await mail.failActivity(matching: activityLabel)
                        return "Error: No mail accounts connected."
                    }
                }
                isIndexOnly = true

            case "search":
                guard let query = arguments.query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
                    await mail.failActivity(matching: activityLabel)
                    return "Error: Missing required 'query' for 'search'."
                }
                let limit = arguments.maxResults ?? SecurityPolicy.gmailPageSize
                guard case .success(let pair) = Self.resolveAccountPair(
                    mail: mail,
                    accountId: arguments.accountId,
                    accountEmail: arguments.accountEmail,
                    requireAccount: true
                ) else {
                    await mail.failActivity(matching: activityLabel)
                    return Self.accountError(
                        mail: mail,
                        accountId: arguments.accountId,
                        accountEmail: arguments.accountEmail,
                        requireAccount: true
                    )
                }
                let searchResult = try await MailSyncActor.shared.search(from: pair.0, query: query, limit: limit)
                result = MailFormatting.formatIndex(searchResult, account: pair.1)
                isIndexOnly = true

            case "read_message":
                guard let messageId = arguments.messageId, !messageId.isEmpty else {
                    await mail.failActivity(matching: activityLabel)
                    return "Error: Missing required 'messageId' for 'read_message'."
                }
                guard case .success(let pair) = Self.resolveAccountPair(
                    mail: mail,
                    accountId: arguments.accountId,
                    accountEmail: arguments.accountEmail,
                    requireAccount: true
                ) else {
                    await mail.failActivity(matching: activityLabel)
                    return Self.accountError(
                        mail: mail,
                        accountId: arguments.accountId,
                        accountEmail: arguments.accountEmail,
                        requireAccount: true
                    )
                }
                let content = try await MailSyncActor.shared.readMessage(from: pair.0, id: messageId)
                result = MailFormatting.formatReadContent(content, account: pair.1)
                readAccountId = pair.1.id
                readMessageIds = [messageId]

            case "archive_message":
                guard let messageId = arguments.messageId, !messageId.isEmpty else {
                    await mail.failActivity(matching: activityLabel)
                    return "Error: Missing required 'messageId' for 'archive_message'."
                }
                guard case .success(let pair) = Self.resolveAccountPair(
                    mail: mail,
                    accountId: arguments.accountId,
                    accountEmail: arguments.accountEmail,
                    requireAccount: true
                ) else {
                    await mail.failActivity(matching: activityLabel)
                    return Self.accountError(
                        mail: mail,
                        accountId: arguments.accountId,
                        accountEmail: arguments.accountEmail,
                        requireAccount: true
                    )
                }
                try await MailSyncActor.shared.archive(from: pair.0, id: messageId)
                result = "Successfully archived message \(messageId) on account \(pair.1.accountLabel)."

            case "mark_read":
                guard let messageId = arguments.messageId, !messageId.isEmpty else {
                    await mail.failActivity(matching: activityLabel)
                    return "Error: Missing required 'messageId' for 'mark_read'."
                }
                guard case .success(let pair) = Self.resolveAccountPair(
                    mail: mail,
                    accountId: arguments.accountId,
                    accountEmail: arguments.accountEmail,
                    requireAccount: true
                ) else {
                    await mail.failActivity(matching: activityLabel)
                    return Self.accountError(
                        mail: mail,
                        accountId: arguments.accountId,
                        accountEmail: arguments.accountEmail,
                        requireAccount: true
                    )
                }
                try await MailSyncActor.shared.markRead(from: pair.0, id: messageId)
                result = "Successfully marked message \(messageId) as read on account \(pair.1.accountLabel)."

            case "create_draft":
                guard case .success(let pair) = Self.resolveAccountPair(
                    mail: mail,
                    accountId: arguments.accountId,
                    accountEmail: arguments.accountEmail,
                    requireAccount: true
                ) else {
                    await mail.failActivity(matching: activityLabel)
                    return Self.accountError(
                        mail: mail,
                        accountId: arguments.accountId,
                        accountEmail: arguments.accountEmail,
                        requireAccount: true
                    )
                }
                guard let to = arguments.to, !to.isEmpty,
                      let subject = arguments.subject,
                      let body = arguments.body else {
                    await mail.failActivity(matching: activityLabel)
                    return "Error: Missing required fields ('to', 'subject', 'body') for 'create_draft'."
                }
                let draft = MailDraft(
                    to: to,
                    subject: subject,
                    body: body,
                    inReplyToMessageId: arguments.inReplyToMessageId,
                    threadId: arguments.threadId
                )
                let draftId = try await MailSyncActor.shared.createDraft(from: pair.0, draft: draft)
                result = "Successfully created draft (draft_id: \(draftId)) on account \(pair.1.accountLabel)."

            case "send_email", "reply_to_message":
                guard case .success(let pair) = Self.resolveAccountPair(
                    mail: mail,
                    accountId: arguments.accountId,
                    accountEmail: arguments.accountEmail,
                    requireAccount: true
                ) else {
                    await mail.failActivity(matching: activityLabel)
                    return Self.accountError(
                        mail: mail,
                        accountId: arguments.accountId,
                        accountEmail: arguments.accountEmail,
                        requireAccount: true
                    )
                }
                guard let to = arguments.to, !to.isEmpty,
                      let subject = arguments.subject,
                      let body = arguments.body else {
                    await mail.failActivity(matching: activityLabel)
                    return "Error: Missing required fields ('to', 'subject', 'body') for '\(arguments.action)'."
                }
                if arguments.action == "reply_to_message" {
                    guard let replyId = arguments.inReplyToMessageId, !replyId.isEmpty else {
                        await mail.failActivity(matching: activityLabel)
                        return "Error: Missing required 'inReplyToMessageId' for 'reply_to_message'."
                    }
                    _ = replyId
                }
                let draft = MailDraft(
                    to: to,
                    subject: subject,
                    body: body,
                    inReplyToMessageId: arguments.inReplyToMessageId,
                    threadId: arguments.threadId
                )
                let draftId = try await MailSyncActor.shared.createDraft(from: pair.0, draft: draft)
                let pendingId = UUID()
                let preview = Self.bodyPreview(body)
                let pending = PendingMailSendRequest(
                    id: pendingId,
                    accountId: pair.1.id,
                    accountLabel: pair.1.accountLabel,
                    draftId: draftId,
                    to: to,
                    subject: subject,
                    bodyPreview: preview
                )
                await workspace.setPendingMailSend(pending)
                result = """
                Draft created on account \(pair.1.accountLabel). Email NOT sent yet — awaiting user confirmation in the app.

                pending_send_id: \(pendingId.uuidString)
                draft_id: \(draftId)
                account_id: \(pair.1.id.uuidString)
                to: \(to)
                subject: \(subject)

                Tell the user their draft is ready and they must confirm send in Zoro before it goes out.
                """

            default:
                await mail.failActivity(matching: activityLabel)
                return "Error: Invalid action '\(arguments.action)'."
            }

            await mail.completeActivity(matching: activityLabel)
            Task { await mail.refreshSnapshot() }
            return await finalize(
                result,
                accountId: readAccountId,
                readMessageIds: readMessageIds,
                isIndexOnly: isIndexOnly
            )
        } catch {
            await mail.failActivity(matching: activityLabel)
            if let mailError = error as? MailError {
                return "Error: \(mailError.localizedDescription)"
            }
            return "Error: \(error.localizedDescription)"
        }
    }

    private static func bodyPreview(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 280 { return trimmed }
        return String(trimmed.prefix(280)) + "…"
    }

    private static func resolveAccountPair(
        mail: MailManager,
        accountId: String?,
        accountEmail: String?,
        requireAccount: Bool
    ) -> Result<(any MailProvider, MailAccount), MailAccountResolutionFailure> {
        mail.resolveProvider(accountId: accountId, accountEmail: accountEmail, requireAccount: requireAccount)
    }

    private static func accountError(
        mail: MailManager,
        accountId: String?,
        accountEmail: String?,
        requireAccount: Bool
    ) -> String {
        if case .failure(let error) = resolveAccountPair(
            mail: mail,
            accountId: accountId,
            accountEmail: accountEmail,
            requireAccount: requireAccount
        ) {
            return error.message
        }
        return "Error: Could not resolve mail account."
    }

    private func finalize(
        _ result: String,
        accountId: UUID?,
        readMessageIds: [String],
        isIndexOnly: Bool
    ) async -> String {
        await MainActor.run {
            if isIndexOnly {
                MailReadAuditor.recordIndexFetch(output: result)
            }
            if let accountId, !readMessageIds.isEmpty {
                MailManager.shared.recordMessagesRead(accountId: accountId, messageIds: readMessageIds)
                MailReadAuditor.recordFullRead()
            }
        }
        let footer = await MailManager.shared.sessionReadFooter()
        return result + "\n\n" + footer
    }
}
