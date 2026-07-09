//
//  GmailMailProvider.swift
//  zoro
//

import Foundation

struct GmailMailProvider: MailProvider {
    let accountId: UUID

    init(accountId: UUID) {
        self.accountId = accountId
    }

    func fetchUnread(limit: Int) async throws -> MailFetchResult {
        let service = try await authenticatedService()
        let page = try await service.fetchUnreadSummaries(limit: limit)
        return makeFetchResult(
            summaries: page.summaries,
            action: "fetch_unread",
            query: "in:inbox is:unread",
            fetchComplete: page.fetchComplete,
            nextPageToken: page.nextPageToken,
            indexOnly: true
        )
    }

    func search(query: String, limit: Int) async throws -> MailFetchResult {
        let service = try await authenticatedService()
        let page = try await service.searchSummaries(query: query, limit: limit)
        return makeFetchResult(
            summaries: page.summaries,
            action: "search",
            query: query,
            fetchComplete: page.fetchComplete,
            nextPageToken: page.nextPageToken,
            indexOnly: true
        )
    }

    func readMessage(id: String) async throws -> MailMessageContent {
        let service = try await authenticatedService()
        do {
            let content = try await service.fetchMessageContent(id: id)
            return mapContent(content)
        } catch {
            throw mapError(error)
        }
    }

    func archive(id: String) async throws {
        let service = try await authenticatedService()
        do {
            _ = try await service.archiveMessage(id: id)
        } catch {
            throw mapError(error)
        }
    }

    func markRead(id: String) async throws {
        let service = try await authenticatedService()
        do {
            _ = try await service.markMessageAsRead(id: id)
        } catch {
            throw mapError(error)
        }
    }

    func createDraft(_ draft: MailDraft) async throws -> String {
        let service = try await authenticatedService()
        do {
            let record = try await service.createDraftRecord(
                to: draft.to,
                subject: draft.subject,
                body: draft.body,
                cc: nil,
                bcc: nil,
                threadId: draft.threadId
            )
            return record.draftId
        } catch {
            throw mapError(error)
        }
    }

    func send(draftId: String) async throws {
        let service = try await authenticatedService()
        do {
            try await service.sendDraft(draftId: draftId)
        } catch {
            throw mapError(error)
        }
    }

    // MARK: - Private

    private func authenticatedService() async throws -> GmailService {
        do {
            return try await GmailService.makeAuthenticated(accountId: accountId)
        } catch let error as GmailAuthError {
            throw mapError(error)
        }
    }

    private func makeFetchResult(
        summaries: [GmailMessageSummary],
        action: String,
        query: String?,
        fetchComplete: Bool,
        nextPageToken: String?,
        indexOnly: Bool
    ) -> MailFetchResult {
        let mapped = summaries.map { mapSummary($0) }
        var warnings = indexWarnings(indexOnly: indexOnly)
        if !fetchComplete {
            warnings.append("More messages remain. Re-sync with pagination or a higher limit.")
        }

        let report = MailFetchReport(
            action: action,
            query: query,
            accountId: accountId,
            itemsFetched: mapped.count,
            fetchComplete: fetchComplete,
            nextPageToken: nextPageToken,
            warnings: warnings
        )
        return MailFetchResult(summaries: mapped, report: report)
    }

    private func mapSummary(_ summary: GmailMessageSummary) -> MailMessageSummary {
        MailMessageSummary(
            id: summary.id,
            threadId: summary.threadId,
            accountId: accountId,
            from: summary.from,
            to: summary.to,
            subject: summary.subject,
            snippet: summary.snippet,
            receivedAt: GmailMailDateParser.parse(summary.date),
            isUnread: summary.isUnread,
            labelIds: summary.labelIds
        )
    }

    private func mapContent(_ content: GmailMessageContent) -> MailMessageContent {
        MailMessageContent(
            summary: mapSummary(content.summary),
            body: content.body,
            bodyComplete: content.bodyComplete,
            bodySource: content.bodySource,
            attachments: content.attachments.map {
                MailAttachmentInfo(
                    filename: $0.filename,
                    mimeType: $0.mimeType,
                    size: $0.size,
                    attachmentId: $0.attachmentId
                )
            }
        )
    }

    private func indexWarnings(indexOnly: Bool) -> [String] {
        guard indexOnly else { return [] }
        return [
            "Results are an INDEX with snippets only.",
            "Call readMessage for full bodies before summarizing.",
            "Never invent message IDs — only use IDs from this output."
        ]
    }

    private func mapError(_ error: Error) -> MailError {
        switch error {
        case let auth as GmailAuthError:
            switch auth {
            case .accountNotConnected, .notConnected:
                return .authenticationFailed(accountId: accountId, detail: auth.localizedDescription)
            case .tokenRefreshFailed(let detail), .authorizationFailed(let detail):
                return .authenticationFailed(accountId: accountId, detail: detail)
            case .networkError(let detail):
                return .networkError(detail)
            default:
                return .providerError(.gmail, auth.localizedDescription)
            }
        case let mail as MailError:
            return mail
        default:
            return .providerError(.gmail, error.localizedDescription)
        }
    }
}

// MARK: - Date parsing

enum GmailMailDateParser {
    private static let rfc2822: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()

    private static let rfc2822NoWeekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()

    static func parse(_ value: String) -> Date {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "unknown" else {
            return Date.distantPast
        }
        if let date = rfc2822.date(from: trimmed) { return date }
        if let date = rfc2822NoWeekday.date(from: trimmed) { return date }
        if let date = ISO8601DateFormatter().date(from: trimmed) { return date }
        return Date.distantPast
    }
}
