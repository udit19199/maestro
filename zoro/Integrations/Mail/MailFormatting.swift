//
//  MailFormatting.swift
//  zoro
//
//  Structured tool output formatting for manage_mail.
//

import Foundation

enum MailFormatting {
    static func formatIndex(_ result: MailFetchResult, account: MailAccount) -> String {
        let report = result.report.formatted()
        var lines = [report, "", "=== MESSAGE INDEX (SNIPPETS ONLY) ==="]
        for (index, summary) in result.summaries.enumerated() {
            lines.append("[\(index + 1)] message_id: \(summary.id)")
            lines.append("    account_id: \(summary.accountId.uuidString)")
            lines.append("    account_label: \(account.accountLabel)")
            lines.append("    from: \(summary.from)")
            lines.append("    subject: \(summary.subject)")
            lines.append("    date: \(ISO8601DateFormatter().string(from: summary.receivedAt))")
            lines.append("    unread: \(summary.isUnread)")
            lines.append("    snippet: \(summary.snippet)")
        }
        if result.summaries.isEmpty {
            lines.append("(no messages)")
        }
        lines.append("=== END INDEX ===")
        return lines.joined(separator: "\n")
    }

    static func formatMergedIndex(results: [(MailFetchResult, MailAccount)]) -> String {
        var lines = ["=== MAIL FETCH REPORT ===", "action: list_unread", "items_fetched: \(results.reduce(0) { $0 + $1.0.summaries.count })", "fetch_complete: true", "=== END REPORT ===", "", "=== MESSAGE INDEX (SNIPPETS ONLY) ==="]
        var counter = 1
        for (result, account) in results {
            for summary in result.summaries {
                lines.append("[\(counter)] message_id: \(summary.id)")
                lines.append("    account_id: \(summary.accountId.uuidString)")
                lines.append("    account_label: \(account.accountLabel)")
                lines.append("    from: \(summary.from)")
                lines.append("    subject: \(summary.subject)")
                lines.append("    date: \(ISO8601DateFormatter().string(from: summary.receivedAt))")
                lines.append("    unread: \(summary.isUnread)")
                lines.append("    snippet: \(summary.snippet)")
                counter += 1
            }
        }
        if counter == 1 {
            lines.append("(no messages)")
        }
        lines.append("=== END INDEX ===")
        return lines.joined(separator: "\n")
    }

    static func formatReadContent(_ content: MailMessageContent, account: MailAccount) -> String {
        let report = MailFetchReport(
            action: "read_message",
            query: nil,
            accountId: content.summary.accountId,
            itemsFetched: 1,
            fetchComplete: true,
            nextPageToken: nil,
            warnings: content.bodyComplete ? [] : ["Body truncated — do not infer missing content."]
        ).formatted()

        let body = """
        message_id: \(content.summary.id)
        account_id: \(content.summary.accountId.uuidString)
        account_label: \(account.accountLabel)
        from: \(content.summary.from)
        to: \(content.summary.to)
        subject: \(content.summary.subject)
        date: \(ISO8601DateFormatter().string(from: content.summary.receivedAt))
        body_complete: \(content.bodyComplete)
        body_source: \(content.bodySource)

        --- BODY ---
        \(content.body)
        """

        var attachmentSection = ""
        if !content.attachments.isEmpty {
            attachmentSection = "\n\n--- ATTACHMENTS (metadata only) ---\n"
            for attachment in content.attachments {
                attachmentSection += "- \(attachment.filename) (\(attachment.mimeType), \(attachment.size) bytes)\n"
            }
        }

        return report + "\n\n" + body + attachmentSection
    }

    static func formatStatus(accounts: [(MailAccount, MailAccountSyncStatus?)], totalUnread: Int) -> String {
        var lines = [
            "=== MAIL FETCH REPORT ===",
            "action: get_status",
            "fetch_complete: true",
            "=== END REPORT ===",
            "",
            "total_unread: \(totalUnread)",
            "accounts:"
        ]
        for (account, status) in accounts {
            let statusText: String
            switch status {
            case .some(.ok(let count)):
                statusText = "ok, unread: \(count)"
            case .some(.error(let message)):
                statusText = "error: \(message)"
            case .some(.syncing):
                statusText = "syncing"
            default:
                statusText = "idle"
            }
            lines.append("- \(account.accountLabel) (\(account.email.isEmpty ? account.provider.rawValue : account.email))")
            lines.append("  account_id: \(account.id.uuidString)")
            lines.append("  provider: \(account.provider.rawValue)")
            lines.append("  status: \(statusText)")
        }
        return lines.joined(separator: "\n")
    }
}
