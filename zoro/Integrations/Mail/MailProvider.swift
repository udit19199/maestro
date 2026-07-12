//
//  MailProvider.swift
//  zoro
//

import Foundation

// MARK: - Protocol

protocol MailProvider: Sendable {
    /// Must be readable from `MailSyncActor` and other non-MainActor contexts.
    nonisolated var accountId: UUID { get }

    func fetchUnread(limit: Int) async throws -> MailFetchResult
    func search(query: String, limit: Int) async throws -> MailFetchResult
    func readMessage(id: String) async throws -> MailMessageContent
    func archive(id: String) async throws
    func markRead(id: String) async throws
    func createDraft(_ draft: MailDraft) async throws -> String
    func send(draftId: String) async throws
}

// MARK: - Value types

struct MailMessageSummary: Sendable, Equatable, Identifiable {
    let id: String
    let threadId: String?
    let accountId: UUID
    let from: String
    let to: String
    let subject: String
    let snippet: String
    let receivedAt: Date
    let isUnread: Bool
    let labelIds: [String]
}

struct MailAttachmentInfo: Sendable, Equatable {
    let filename: String
    let mimeType: String
    let size: Int
    let attachmentId: String?
}

struct MailMessageContent: Sendable, Equatable {
    let summary: MailMessageSummary
    let body: String
    let bodyComplete: Bool
    let bodySource: String
    let attachments: [MailAttachmentInfo]
}

struct MailFetchReport: Sendable, Equatable {
    let action: String
    let query: String?
    let accountId: UUID
    let itemsFetched: Int
    let fetchComplete: Bool
    let nextPageToken: String?
    let warnings: [String]

    func formatted(auditBody: String = "") -> String {
        var lines = [
            "=== MAIL FETCH REPORT ===",
            "action: \(action)",
            "account_id: \(accountId.uuidString)",
        ]
        if let query { lines.append("query: \(query)") }
        lines.append("items_fetched: \(itemsFetched)")
        lines.append("fetch_complete: \(fetchComplete)")
        lines.append("next_page_token: \(nextPageToken ?? "none")")
        if !warnings.isEmpty {
            lines.append("warnings:")
            for warning in warnings {
                lines.append("  - \(warning)")
            }
        }
        lines.append("=== END REPORT ===")
        if !auditBody.isEmpty {
            lines.append("")
            lines.append(auditBody)
        }
        return lines.joined(separator: "\n")
    }
}

struct MailFetchResult: Sendable, Equatable {
    let summaries: [MailMessageSummary]
    let report: MailFetchReport
}

struct MailDraft: Sendable, Equatable {
    let to: String
    let subject: String
    let body: String
    let inReplyToMessageId: String?
    let threadId: String?
}

// MARK: - Errors

enum MailError: LocalizedError, Sendable, Equatable {
    case accountNotFound(UUID)
    case providerUnavailable(String)
    case authenticationFailed(accountId: UUID, detail: String)
    case networkError(String)
    case messageNotFound(String)
    case rateLimited
    case unsupportedOperation(String)
    case providerError(MailProviderType, String)

    var errorDescription: String? {
        switch self {
        case .accountNotFound(let id):
            return "Mail account not found: \(id.uuidString)."
        case .providerUnavailable(let detail):
            return "Mail provider unavailable: \(detail)"
        case .authenticationFailed(let accountId, let detail):
            return "Authentication failed for account \(accountId.uuidString): \(detail)"
        case .networkError(let detail):
            return "Mail network error: \(detail)"
        case .messageNotFound(let id):
            return "Message not found: \(id)"
        case .rateLimited:
            return "Mail provider rate limit reached. Try again shortly."
        case .unsupportedOperation(let detail):
            return "Unsupported mail operation: \(detail)"
        case .providerError(let provider, let detail):
            return "\(provider.rawValue) error: \(detail)"
        }
    }
}
