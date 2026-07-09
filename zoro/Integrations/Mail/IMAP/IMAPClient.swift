//
//  IMAPClient.swift
//  zoro
//
//  MailCore2 bridge isolated in an actor for IMAP/SMTP operations.
//

import Foundation
import MailCore
import os

// MARK: - Configuration

struct IMAPClientConfiguration: Sendable {
    let accountId: UUID
    let email: String
    let imapHost: String
    let imapPort: Int
    let smtpHost: String
    let smtpPort: Int

    nonisolated init(account: MailAccount, password: String) throws {
        guard account.provider == .imap else {
            throw MailError.unsupportedOperation("Account is not IMAP.")
        }
        guard let imapHost = account.imapHost, let imapPort = account.imapPort else {
            throw MailError.providerError(.imap, "Missing IMAP host or port.")
        }
        guard let smtpHost = account.smtpHost else {
            throw MailError.providerError(.imap, "Missing SMTP host.")
        }
        self.accountId = account.id
        self.email = account.email
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.smtpHost = smtpHost
        self.smtpPort = 587
        _ = password
    }
}

// MARK: - Message identifiers

enum IMAPMessageID: Sendable, Equatable {
    case inbox(uid: UInt32)
    case folder(path: String, uid: UInt32)

    var encoded: String {
        switch self {
        case .inbox(let uid):
            return "imap://INBOX/\(uid)"
        case .folder(let path, let uid):
            let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            return "imap://\(escaped)/\(uid)"
        }
    }

    nonisolated static func decode(_ raw: String) -> IMAPMessageID? {
        guard raw.hasPrefix("imap://") else { return nil }
        let remainder = String(raw.dropFirst("imap://".count))
        guard let slashIndex = remainder.lastIndex(of: "/") else { return nil }
        let folderPart = String(remainder[..<slashIndex])
        let uidPart = String(remainder[remainder.index(after: slashIndex)...])
        guard let uid = UInt32(uidPart) else { return nil }
        let folder = folderPart.removingPercentEncoding ?? folderPart
        if folder.uppercased() == "INBOX" {
            return .inbox(uid: uid)
        }
        return .folder(path: folder, uid: uid)
    }

    var folderPath: String {
        switch self {
        case .inbox:
            return "INBOX"
        case .folder(let path, _):
            return path
        }
    }

    var uid: UInt32 {
        switch self {
        case .inbox(let uid), .folder(_, let uid):
            return uid
        }
    }
}

// MARK: - Folder cache

private struct IMAPFolderPaths: Sendable {
    let inbox: String
    let archive: String
    let drafts: String
}

// MARK: - Client

actor IMAPClient {
    private static let maxMessagesPerOperation = 250
    private static let maxBodyBytes = 1_048_576

    private let configuration: IMAPClientConfiguration
    private let password: String
    private let logger = Logger(subsystem: "com.zoro.mail", category: "IMAPClient")

    private var cachedFolders: IMAPFolderPaths?

    init(account: MailAccount, password: String) throws {
        self.configuration = try IMAPClientConfiguration(account: account, password: password)
        self.password = password
    }

    // MARK: - Public operations

    func fetchUnread(limit: Int) async throws -> MailFetchResult {
        let folders = try await resolveFolders()
        let cappedLimit = min(max(limit, 1), Self.maxMessagesPerOperation)
        let uids = try await search(folder: folders.inbox, expression: MCOIMAPSearchExpression.searchUnread())
        let summaries = try await fetchSummaries(folder: folders.inbox, uids: uids, limit: cappedLimit)
        let fetchComplete = summaries.count >= min(cappedLimit, Int(uids.count()))

        return MailFetchResult(
            summaries: summaries,
            report: MailFetchReport(
                action: "fetch_unread",
                query: "UNSEEN",
                accountId: configuration.accountId,
                itemsFetched: summaries.count,
                fetchComplete: fetchComplete,
                nextPageToken: fetchComplete ? nil : "more",
                warnings: indexOnlyWarnings()
            )
        )
    }

    func search(query: String, limit: Int) async throws -> MailFetchResult {
        let folders = try await resolveFolders()
        let cappedLimit = min(max(limit, 1), Self.maxMessagesPerOperation)
        let expression = buildSearchExpression(query: query)
        let uids = try await search(folder: folders.inbox, expression: expression)
        let summaries = try await fetchSummaries(folder: folders.inbox, uids: uids, limit: cappedLimit)
        let fetchComplete = summaries.count >= min(cappedLimit, Int(uids.count()))

        return MailFetchResult(
            summaries: summaries,
            report: MailFetchReport(
                action: "search",
                query: query,
                accountId: configuration.accountId,
                itemsFetched: summaries.count,
                fetchComplete: fetchComplete,
                nextPageToken: fetchComplete ? nil : "more",
                warnings: indexOnlyWarnings()
            )
        )
    }

    func readMessage(id: String) async throws -> MailMessageContent {
        guard let messageID = IMAPMessageID.decode(id) else {
            throw MailError.messageNotFound(id)
        }

        let data = try await fetchRFC822(folder: messageID.folderPath, uid: messageID.uid)
        guard let parser = MCOMessageParser(data: data) else {
            throw MailError.providerError(.imap, "Failed to parse message.")
        }

        let summary = try await fetchSingleSummary(folder: messageID.folderPath, uid: messageID.uid)
            ?? makeSummaryFromParser(parser, messageID: messageID, isUnread: false)

        let plainBody = parser.plainTextBodyRendering() ?? ""
        let htmlBody = parser.htmlBodyRendering() ?? ""
        let body = !plainBody.isEmpty ? plainBody : htmlBody
        let truncated = truncateBody(body)

        let attachments = parser.attachments().compactMap { part -> MailAttachmentInfo? in
            guard let attachment = part as? MCOAttachment else { return nil }
            return MailAttachmentInfo(
                filename: attachment.filename ?? "attachment",
                mimeType: attachment.mimeType ?? "application/octet-stream",
                size: Int(attachment.data?.count ?? 0),
                attachmentId: nil
            )
        }

        return MailMessageContent(
            summary: summary,
            body: truncated.text,
            bodyComplete: truncated.complete,
            bodySource: !plainBody.isEmpty ? "text/plain" : "text/html",
            attachments: attachments
        )
    }

    func archive(id: String) async throws {
        guard let messageID = IMAPMessageID.decode(id) else {
            throw MailError.messageNotFound(id)
        }
        let folders = try await resolveFolders()
        let uidSet = indexSet(for: messageID.uid)
        try await moveMessages(from: messageID.folderPath, to: folders.archive, uids: uidSet)
    }

    func markRead(id: String) async throws {
        guard let messageID = IMAPMessageID.decode(id) else {
            throw MailError.messageNotFound(id)
        }
        let uidSet = indexSet(for: messageID.uid)
        try await storeFlags(
            folder: messageID.folderPath,
            uids: uidSet,
            kind: .add,
            flags: .seen
        )
    }

    func createDraft(_ draft: MailDraft) async throws -> String {
        let folders = try await resolveFolders()
        let builder = MCOMessageBuilder()
        builder.header.from = MCOAddress(displayName: configuration.email, mailbox: configuration.email)
        builder.header.to = parseAddresses(draft.to)
        builder.header.subject = draft.subject
        builder.textBody = draft.body

        if let replyId = draft.inReplyToMessageId, let replyUID = IMAPMessageID.decode(replyId) {
            let replyData = try await fetchRFC822(folder: replyUID.folderPath, uid: replyUID.uid)
            if let replyParser = MCOMessageParser(data: replyData) {
                if let messageID = replyParser.header.messageID {
                    builder.header.inReplyTo = [messageID]
                }
                if let references = replyParser.header.references {
                    builder.header.references = references
                }
            }
        }

        guard let messageData = builder.data() else {
            throw MailError.providerError(.imap, "Failed to build draft message.")
        }

        let uid = try await appendMessage(
            folder: folders.drafts,
            data: messageData,
            flags: .draft
        )
        return IMAPMessageID.folder(path: folders.drafts, uid: uid).encoded
    }

    func send(draftId: String) async throws {
        guard let messageID = IMAPMessageID.decode(draftId) else {
            throw MailError.messageNotFound(draftId)
        }

        let data = try await fetchRFC822(folder: messageID.folderPath, uid: messageID.uid)
        try await sendMessage(data: data)
    }

    // MARK: - Sessions

    private func makeIMAPSession() -> MCOIMAPSession {
        let session = MCOIMAPSession()
        session.hostname = configuration.imapHost
        session.port = UInt32(configuration.imapPort)
        session.username = configuration.email
        session.password = password
        session.connectionType = .TLS
        session.authType = .saslLogin
        session.isVoIPEnabled = false
        return session
    }

    private func makeSMTPSession() -> MCOSMTPSession {
        let session = MCOSMTPSession()
        session.hostname = configuration.smtpHost
        session.port = UInt32(configuration.smtpPort)
        session.username = configuration.email
        session.password = password
        session.connectionType = .startTLS
        session.authType = .saslLogin
        return session
    }

    // MARK: - Folder discovery

    private func resolveFolders() async throws -> IMAPFolderPaths {
        if let cachedFolders { return cachedFolders }

        let session = makeIMAPSession()
        let folders = try await runFoldersOperation { completion in
            session.fetchAllFoldersOperation()?.start(completion)
        }

        var inbox = "INBOX"
        var archive = "Archive"
        var drafts = "Drafts"

        for folder in folders {
            guard let path = folder.path else { continue }
            if folder.flags.contains(.inbox) {
                inbox = path
            }
            if folder.flags.contains(.archive) {
                archive = path
            }
            if folder.flags.contains(.drafts) {
                drafts = path
            }
        }

        let resolved = IMAPFolderPaths(inbox: inbox, archive: archive, drafts: drafts)
        cachedFolders = resolved
        return resolved
    }

    // MARK: - Search

    private func buildSearchExpression(query: String) -> MCOIMAPSearchExpression {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return MCOIMAPSearchExpression.searchAll()
        }

        var expressions: [MCOIMAPSearchExpression] = []
        let tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)

        for token in tokens {
            let lower = token.lowercased()
            if lower == "is:unread" || lower == "unread" {
                expressions.append(MCOIMAPSearchExpression.searchUnread())
                continue
            }
            if lower == "in:inbox" || lower == "inbox" {
                continue
            }
            if lower.hasPrefix("from:") {
                let value = String(token.dropFirst(5))
                if !value.isEmpty {
                    expressions.append(MCOIMAPSearchExpression.search(from: value))
                }
                continue
            }
            if lower.hasPrefix("subject:") {
                let value = String(token.dropFirst(8))
                if !value.isEmpty {
                    expressions.append(MCOIMAPSearchExpression.searchSubject(value))
                }
                continue
            }

            let subjectExpr = MCOIMAPSearchExpression.searchSubject(token)
            let bodyExpr = MCOIMAPSearchExpression.searchContent(token)
            expressions.append(MCOIMAPSearchExpression.searchOr(subjectExpr, other: bodyExpr))
        }

        guard let first = expressions.first else {
            return MCOIMAPSearchExpression.searchAll()
        }

        return expressions.dropFirst().reduce(first) { partial, next in
            MCOIMAPSearchExpression.searchAnd(partial, other: next)
        }
    }

    private func search(folder: String, expression: MCOIMAPSearchExpression) async throws -> MCOIndexSet {
        let session = makeIMAPSession()
        return try await runSearchOperation { completion in
            session.searchExpressionOperation(withFolder: folder, expression: expression)?.start(completion)
        }
    }

    // MARK: - Fetch

    private func fetchSummaries(
        folder: String,
        uids: MCOIndexSet,
        limit: Int
    ) async throws -> [MailMessageSummary] {
        guard uids.count() > 0 else { return [] }

        let session = makeIMAPSession()
        let requestKind: MCOIMAPMessagesRequestKind = [
            .headers,
            .flags,
            .internalDate,
            .structure
        ]

        let messages = try await runFetchMessagesOperation { completion in
            session.fetchMessagesOperation(withFolder: folder, requestKind: requestKind, uids: uids)?
                .start(completion)
        }

        let sorted = messages.sorted { lhs, rhs in
            let leftDate = lhs.header.date ?? lhs.header.receivedDate ?? .distantPast
            let rightDate = rhs.header.date ?? rhs.header.receivedDate ?? .distantPast
            return leftDate > rightDate
        }

        return Array(sorted.prefix(limit)).map { message in
            let uid = message.uid
            let messageID: IMAPMessageID = folder.uppercased() == "INBOX"
                ? .inbox(uid: uid)
                : .folder(path: folder, uid: uid)
            let from = formatAddress(message.header.from)
            let to = formatAddressList(message.header.to as? [MCOAddress])
            let subject = message.header.subject ?? "(no subject)"
            let snippet = makeSnippet(subject: subject, from: from)
            let receivedAt = message.header.date ?? message.header.receivedDate ?? Date()
            let isUnread = !message.flags.contains(.seen)

            return MailMessageSummary(
                id: messageID.encoded,
                threadId: message.header.messageID,
                accountId: configuration.accountId,
                from: from,
                to: to,
                subject: subject,
                snippet: snippet,
                receivedAt: receivedAt,
                isUnread: isUnread,
                labelIds: labelIds(for: message)
            )
        }
    }

    private func fetchSingleSummary(folder: String, uid: UInt32) async throws -> MailMessageSummary? {
        let uidSet = indexSet(for: uid)
        let summaries = try await fetchSummaries(folder: folder, uids: uidSet, limit: 1)
        return summaries.first
    }

    private func fetchRFC822(folder: String, uid: UInt32) async throws -> Data {
        let session = makeIMAPSession()
        return try await runDataOperation { completion in
            session.fetchMessageOperation(withFolder: folder, uid: uid)?.start(completion)
        }
    }

    // MARK: - Mutations

    private func moveMessages(from sourceFolder: String, to destFolder: String, uids: MCOIndexSet) async throws {
        let session = makeIMAPSession()
        try await runMoveOperation { completion in
            session.moveMessagesOperation(withFolder: sourceFolder, uids: uids, destFolder: destFolder)?
                .start(completion)
        }
    }

    private func storeFlags(
        folder: String,
        uids: MCOIndexSet,
        kind: MCOIMAPStoreFlagsRequestKind,
        flags: MCOMessageFlag
    ) async throws {
        let session = makeIMAPSession()
        try await runVoidOperation { completion in
            session.storeFlagsOperation(withFolder: folder, uids: uids, kind: kind, flags: flags)?
                .start(completion)
        }
    }

    private func appendMessage(folder: String, data: Data, flags: MCOMessageFlag) async throws -> UInt32 {
        let session = makeIMAPSession()
        return try await runAppendOperation { completion in
            session.appendMessageOperation(withFolder: folder, messageData: data, flags: flags)?
                .start(completion)
        }
    }

    private func sendMessage(data: Data) async throws {
        let session = makeSMTPSession()
        try await runVoidOperation { completion in
            session.sendOperation(with: data)?.start(completion)
        }
    }

    // MARK: - Helpers

    private func indexSet(for uid: UInt32) -> MCOIndexSet {
        MCOIndexSet(index: UInt64(uid))
    }

    private func makeSummaryFromParser(
        _ parser: MCOMessageParser,
        messageID: IMAPMessageID,
        isUnread: Bool
    ) -> MailMessageSummary {
        let from = formatAddress(parser.header.from)
        let to = formatAddressList(parser.header.to as? [MCOAddress])
        let subject = parser.header.subject ?? "(no subject)"
        return MailMessageSummary(
            id: messageID.encoded,
            threadId: parser.header.messageID,
            accountId: configuration.accountId,
            from: from,
            to: to,
            subject: subject,
            snippet: makeSnippet(subject: subject, from: from),
            receivedAt: parser.header.date ?? Date(),
            isUnread: isUnread,
            labelIds: isUnread ? ["UNREAD"] : []
        )
    }

    private func formatAddress(_ address: MCOAddress?) -> String {
        address?.mailbox ?? address?.displayName ?? "unknown"
    }

    private func formatAddressList(_ addresses: [MCOAddress]?) -> String {
        addresses?.compactMap { $0.mailbox ?? $0.displayName }.joined(separator: ", ") ?? ""
    }

    private func makeSnippet(subject: String, from: String) -> String {
        let combined = "\(from) — \(subject)"
        if combined.count <= 120 { return combined }
        return String(combined.prefix(117)) + "..."
    }

    private func labelIds(for message: MCOIMAPMessage) -> [String] {
        var labels: [String] = []
        if !message.flags.contains(.seen) { labels.append("UNREAD") }
        if message.flags.contains(.flagged) { labels.append("FLAGGED") }
        if message.flags.contains(.answered) { labels.append("REPLIED") }
        return labels
    }

    private func parseAddresses(_ raw: String) -> [MCOAddress] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { MCOAddress(displayName: nil, mailbox: String($0)) }
    }

    private func truncateBody(_ body: String) -> (text: String, complete: Bool) {
        let maxBytes = Self.maxBodyBytes
        let utf8 = Array(body.utf8)
        if utf8.count <= maxBytes {
            return (body, true)
        }
        let truncated = String(decoding: utf8.prefix(maxBytes), as: UTF8.self)
        return (
            truncated + "\n\n[BODY TRUNCATED AT \(maxBytes) BYTES — DO NOT INFER MISSING CONTENT]",
            false
        )
    }

    private func indexOnlyWarnings() -> [String] {
        ["INDEX ONLY — call read_message before summarizing body content."]
    }

    // MARK: - Async bridge

    private func runFoldersOperation(
        _ start: (@escaping (Error?, [MCOIMAPFolder]?) -> Void) -> Void
    ) async throws -> [MCOIMAPFolder] {
        try await withCheckedThrowingContinuation { continuation in
            start { error, folders in
                if let error {
                    continuation.resume(throwing: self.mapError(error))
                    return
                }
                continuation.resume(returning: folders ?? [])
            }
        }
    }

    private func runSearchOperation(
        _ start: (@escaping (Error?, MCOIndexSet?) -> Void) -> Void
    ) async throws -> MCOIndexSet {
        try await withCheckedThrowingContinuation { continuation in
            start { error, indexSet in
                if let error {
                    continuation.resume(throwing: self.mapError(error))
                    return
                }
                continuation.resume(returning: indexSet ?? MCOIndexSet())
            }
        }
    }

    private func runFetchMessagesOperation(
        _ start: (@escaping (Error?, [MCOIMAPMessage]?, MCOIndexSet?) -> Void) -> Void
    ) async throws -> [MCOIMAPMessage] {
        try await withCheckedThrowingContinuation { continuation in
            start { error, messages, _ in
                if let error {
                    continuation.resume(throwing: self.mapError(error))
                    return
                }
                continuation.resume(returning: messages ?? [])
            }
        }
    }

    private func runDataOperation(
        _ start: (@escaping (Error?, Data?) -> Void) -> Void
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            start { error, data in
                if let error {
                    continuation.resume(throwing: self.mapError(error))
                    return
                }
                continuation.resume(returning: data ?? Data())
            }
        }
    }

    private func runAppendOperation(
        _ start: (@escaping (Error?, UInt32) -> Void) -> Void
    ) async throws -> UInt32 {
        try await withCheckedThrowingContinuation { continuation in
            start { error, createdUID in
                if let error {
                    continuation.resume(throwing: self.mapError(error))
                    return
                }
                continuation.resume(returning: createdUID)
            }
        }
    }

    private func runMoveOperation(
        _ start: (@escaping (Error?, [AnyHashable: Any]?) -> Void) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            start { error, _ in
                if let error {
                    continuation.resume(throwing: self.mapError(error))
                    return
                }
                continuation.resume()
            }
        }
    }

    private func runVoidOperation(
        _ start: (@escaping (Error?) -> Void) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            start { error in
                if let error {
                    continuation.resume(throwing: self.mapError(error))
                    return
                }
                continuation.resume()
            }
        }
    }

    private func mapError(_ error: Error) -> MailError {
        let nsError = error as NSError
        let detail = nsError.localizedDescription
        if nsError.domain == "MCOErrorDomain", nsError.code == 5 {
            return .authenticationFailed(accountId: configuration.accountId, detail: detail)
        }
        return .providerError(.imap, detail)
    }
}
