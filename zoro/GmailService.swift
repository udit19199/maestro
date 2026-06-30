//
//  GmailService.swift
//  zoro
//
//  Reliable Gmail API client with pagination, retries, and structured fetch reports.
//

import Foundation

struct GmailFetchReport {
    let action: String
    let query: String?
    let labelIds: [String]?
    let resultSizeEstimate: Int?
    let itemsFetched: Int
    let fetchComplete: Bool
    let nextPageToken: String?
    let warnings: [String]
    let body: String

    func formatted() -> String {
        var lines = [
            "=== GMAIL FETCH REPORT ===",
            "action: \(action)",
        ]
        if let query { lines.append("query: \(query)") }
        if let labelIds, !labelIds.isEmpty { lines.append("label_ids: \(labelIds.joined(separator: ", "))") }
        if let resultSizeEstimate { lines.append("result_size_estimate: \(resultSizeEstimate)") }
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
        lines.append("")
        lines.append(body)
        return lines.joined(separator: "\n")
    }
}

struct GmailMessageSummary {
    let id: String
    let threadId: String
    let from: String
    let to: String
    let subject: String
    let date: String
    let snippet: String
    let labelIds: [String]
    let isUnread: Bool
}

struct GmailMessageContent {
    let summary: GmailMessageSummary
    let body: String
    let bodyComplete: Bool
    let bodySource: String
    let attachments: [GmailAttachmentInfo]
}

struct GmailAttachmentInfo {
    let filename: String
    let mimeType: String
    let size: Int
    let attachmentId: String?
}

struct GmailStatus {
    let emailAddress: String
    let messagesTotal: Int
    let threadsTotal: Int
    let unreadInbox: Int
    let historyId: String
}

struct GmailService {
    let accessToken: String

    static func makeAuthenticated() async throws -> GmailService {
        let token = try await GmailAuthManager.shared.getValidAccessToken()
        return GmailService(accessToken: token)
    }

    // MARK: - Status

    func fetchStatus() async throws -> GmailStatus {
        let profile = try await decode(GmailProfileDetail.self, from: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!)
        let unread = try await countUnreadInbox()
        return GmailStatus(
            emailAddress: profile.emailAddress,
            messagesTotal: profile.messagesTotal,
            threadsTotal: profile.threadsTotal,
            unreadInbox: unread,
            historyId: profile.historyId
        )
    }

    func fetchInboxPreview(maxItems: Int = 8) async throws -> [GmailMessageSummary] {
        let refs = try await fetchMessageRefs(
            query: "in:inbox",
            labelIds: nil,
            pageToken: nil,
            maxResults: maxItems,
            hardCap: maxItems
        )
        return try await fetchSummaries(for: refs.refs)
    }

    // MARK: - List / Search

    func listMessages(
        labelIds: [String],
        maxResults: Int?,
        fetchAll: Bool,
        pageToken: String?
    ) async throws -> GmailFetchReport {
        let perPage = min(maxResults ?? SecurityPolicy.gmailPageSize, SecurityPolicy.gmailPageSize)
        let hardCap = fetchAll ? SecurityPolicy.maxGmailMessagesPerOperation : perPage

        let page = try await fetchMessageRefs(
            query: nil,
            labelIds: labelIds,
            pageToken: pageToken,
            maxResults: perPage,
            hardCap: hardCap,
            fetchAllPages: fetchAll
        )

        let summaries = try await fetchSummaries(for: page.refs)
        let body = formatSummaries(summaries, indexOnly: true)

        var warnings = indexWarnings()
        if !page.fetchComplete {
            warnings.append("More messages remain. Call again with pageToken '\(page.nextPageToken ?? "")' or set fetchAll: true.")
        }

        return GmailFetchReport(
            action: "list_messages",
            query: nil,
            labelIds: labelIds,
            resultSizeEstimate: page.resultSizeEstimate,
            itemsFetched: summaries.count,
            fetchComplete: page.fetchComplete,
            nextPageToken: page.nextPageToken,
            warnings: warnings,
            body: body
        )
    }

    func searchMessages(
        query: String,
        maxResults: Int?,
        fetchAll: Bool,
        pageToken: String?
    ) async throws -> GmailFetchReport {
        let perPage = min(maxResults ?? SecurityPolicy.gmailPageSize, SecurityPolicy.gmailPageSize)
        let hardCap = fetchAll ? SecurityPolicy.maxGmailMessagesPerOperation : perPage

        let page = try await fetchMessageRefs(
            query: query,
            labelIds: nil,
            pageToken: pageToken,
            maxResults: perPage,
            hardCap: hardCap,
            fetchAllPages: fetchAll
        )

        let summaries = try await fetchSummaries(for: page.refs)
        let body = formatSummaries(summaries, indexOnly: true)

        var warnings = indexWarnings()
        if !page.fetchComplete {
            warnings.append("More matches remain. Call again with pageToken '\(page.nextPageToken ?? "")' or set fetchAll: true.")
        }

        return GmailFetchReport(
            action: "search_messages",
            query: query,
            labelIds: nil,
            resultSizeEstimate: page.resultSizeEstimate,
            itemsFetched: summaries.count,
            fetchComplete: page.fetchComplete,
            nextPageToken: page.nextPageToken,
            warnings: warnings,
            body: body
        )
    }

    // MARK: - Read

    func readMessage(id: String) async throws -> GmailFetchReport {
        let content = try await fetchMessageContent(id: id)
        let body = formatMessageContent(content, index: 1, total: 1)

        var warnings: [String] = []
        if !content.bodyComplete {
            warnings.append("Message body was truncated at \(SecurityPolicy.maxGmailBodyBytes) bytes. Do not infer missing content.")
        }
        if !content.attachments.isEmpty {
            warnings.append("Message has \(content.attachments.count) attachment(s) not included in body. List attachment filenames only.")
        }

        return GmailFetchReport(
            action: "read_message",
            query: nil,
            labelIds: nil,
            resultSizeEstimate: 1,
            itemsFetched: 1,
            fetchComplete: true,
            nextPageToken: nil,
            warnings: warnings,
            body: body
        )
    }

    func readThread(threadId: String) async throws -> GmailFetchReport {
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/threads/\(threadId)")!
        components.queryItems = [URLQueryItem(name: "format", value: "full")]
        let thread = try await decode(GmailThreadDetail.self, from: components.url!)

        guard let messages = thread.messages, !messages.isEmpty else {
            return GmailFetchReport(
                action: "read_thread",
                query: nil,
                labelIds: nil,
                resultSizeEstimate: 0,
                itemsFetched: 0,
                fetchComplete: true,
                nextPageToken: nil,
                warnings: ["Thread \(threadId) contains no messages."],
                body: "No messages in thread."
            )
        }

        var parts: [String] = []
        var warnings: [String] = []
        for (index, message) in messages.enumerated() {
            let content = contentFromDetail(message)
            parts.append(formatMessageContent(content, index: index + 1, total: messages.count))
            if !content.bodyComplete {
                warnings.append("Message \(content.summary.id) body truncated.")
            }
        }

        return GmailFetchReport(
            action: "read_thread",
            query: nil,
            labelIds: nil,
            resultSizeEstimate: messages.count,
            itemsFetched: messages.count,
            fetchComplete: true,
            nextPageToken: nil,
            warnings: warnings,
            body: parts.joined(separator: "\n\n---\n\n")
        )
    }

    func readMessages(ids: [String]) async throws -> GmailFetchReport {
        let uniqueIds = Array(Set(ids.filter { !$0.isEmpty }))
        guard !uniqueIds.isEmpty else {
            throw GmailAuthError.networkError("No message IDs provided.")
        }

        let cappedIds = Array(uniqueIds.prefix(SecurityPolicy.maxGmailBatchRead))
        var parts: [String] = []
        var warnings: [String] = []

        if uniqueIds.count > cappedIds.count {
            warnings.append("Batch limited to \(SecurityPolicy.maxGmailBatchRead) messages. \(uniqueIds.count - cappedIds.count) IDs skipped.")
        }

        for (index, id) in cappedIds.enumerated() {
            do {
                let content = try await fetchMessageContent(id: id)
                parts.append(formatMessageContent(content, index: index + 1, total: cappedIds.count))
                if !content.bodyComplete {
                    warnings.append("Message \(id) body truncated.")
                }
            } catch {
                parts.append("[\(index + 1)/\(cappedIds.count)] id=\(id)\nERROR: \(error.localizedDescription)")
                warnings.append("Failed to read message \(id).")
            }
        }

        return GmailFetchReport(
            action: "read_messages",
            query: nil,
            labelIds: nil,
            resultSizeEstimate: cappedIds.count,
            itemsFetched: parts.count,
            fetchComplete: uniqueIds.count <= cappedIds.count,
            nextPageToken: nil,
            warnings: warnings,
            body: parts.joined(separator: "\n\n---\n\n")
        )
    }

    // MARK: - Write

    func sendEmail(to: String, subject: String, body: String, cc: String?, bcc: String?) async throws -> String {
        let rawMessage = buildRawEmail(to: to, subject: subject, body: body, cc: cc, bcc: bcc)
        let encoded = base64URLEncode(Data(rawMessage.utf8))

        var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["raw": encoded])

        let (data, response) = try await performRequest(request)
        guard response.statusCode == 200 else {
            throw GmailAuthError.networkError("Send failed: \(String(data: data, encoding: .utf8) ?? "Unknown error")")
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

        let (data, response) = try await performRequest(request)
        guard response.statusCode == 200 else {
            throw GmailAuthError.networkError("Trash failed: \(String(data: data, encoding: .utf8) ?? "Unknown error")")
        }
        return "Successfully moved message \(id) to trash."
    }

    func markMessageAsRead(id: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)/modify")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["removeLabelIds": ["UNREAD"]])

        let (data, response) = try await performRequest(request)
        guard response.statusCode == 200 else {
            throw GmailAuthError.networkError("Mark read failed: \(String(data: data, encoding: .utf8) ?? "Unknown error")")
        }
        return "Successfully marked message \(id) as read."
    }

    func readAttachment(messageId: String, attachmentId: String) async throws -> GmailFetchReport {
        let content = try await fetchMessageContent(id: messageId)
        guard let attachment = content.attachments.first(where: { $0.attachmentId == attachmentId }) else {
            throw GmailAuthError.networkError("Attachment \(attachmentId) not found on message \(messageId).")
        }

        guard SecurityPolicy.isGmailTextAttachment(attachment.mimeType) else {
            throw GmailAuthError.networkError("Attachment '\(attachment.filename)' (\(attachment.mimeType)) is not a supported text type. Supported: plain text, HTML, JSON, CSV, XML.")
        }

        if attachment.size > SecurityPolicy.maxGmailAttachmentBytes {
            throw GmailAuthError.networkError("Attachment exceeds \(SecurityPolicy.maxGmailAttachmentBytes) byte limit.")
        }

        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(messageId)/attachments/\(attachmentId)")!
        let attachmentBody = try await decode(GmailAttachmentBody.self, from: url)
        guard let encoded = attachmentBody.data, let raw = decodeBase64URL(encoded) else {
            throw GmailAuthError.networkError("Could not decode attachment data.")
        }

        let text = attachment.mimeType.lowercased().contains("html") ? stripHTML(raw) : raw
        let truncated = SecurityPolicy.truncateOutput(
            text,
            maxBytes: SecurityPolicy.maxGmailAttachmentBytes,
            suffix: "\n\n[ATTACHMENT TRUNCATED — DO NOT INFER MISSING CONTENT]"
        )

        let body = """
        message_id: \(messageId)
        attachment_id: \(attachmentId)
        filename: \(attachment.filename)
        mime_type: \(attachment.mimeType)
        size_bytes: \(attachment.size)
        body_complete: \(text.utf8.count <= SecurityPolicy.maxGmailAttachmentBytes)

        --- ATTACHMENT CONTENT ---
        \(truncated.isEmpty ? "(Empty attachment)" : truncated)
        """

        return GmailFetchReport(
            action: "read_attachment",
            query: nil,
            labelIds: nil,
            resultSizeEstimate: 1,
            itemsFetched: 1,
            fetchComplete: true,
            nextPageToken: nil,
            warnings: ["Attachment content fetched — safe to summarize this text."],
            body: body
        )
    }

    // MARK: - Internals

    private struct MessageRefPage {
        let refs: [GmailMessageRef]
        let nextPageToken: String?
        let resultSizeEstimate: Int?
        let fetchComplete: Bool
    }

    private func fetchMessageRefs(
        query: String?,
        labelIds: [String]?,
        pageToken: String?,
        maxResults: Int,
        hardCap: Int,
        fetchAllPages: Bool = false
    ) async throws -> MessageRefPage {
        var allRefs: [GmailMessageRef] = []
        var token = pageToken
        var resultSizeEstimate: Int?
        var lastNextToken: String?

        repeat {
            var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
            var queryItems = [URLQueryItem(name: "maxResults", value: String(maxResults))]
            if let query { queryItems.append(URLQueryItem(name: "q", value: query)) }
            if let labelIds {
                for label in labelIds {
                    queryItems.append(URLQueryItem(name: "labelIds", value: label))
                }
            }
            if let token { queryItems.append(URLQueryItem(name: "pageToken", value: token)) }
            components.queryItems = queryItems

            let list = try await decode(GmailMessageList.self, from: components.url!)
            resultSizeEstimate = list.resultSizeEstimate ?? resultSizeEstimate
            allRefs.append(contentsOf: list.messages ?? [])
            lastNextToken = list.nextPageToken
            token = list.nextPageToken

            if allRefs.count >= hardCap { break }
        } while fetchAllPages && token != nil

        let capped = Array(allRefs.prefix(hardCap))
        let fetchComplete = token == nil && capped.count == allRefs.count

        return MessageRefPage(
            refs: capped,
            nextPageToken: fetchComplete ? nil : (lastNextToken ?? token),
            resultSizeEstimate: resultSizeEstimate,
            fetchComplete: fetchComplete
        )
    }

    private func fetchSummaries(for refs: [GmailMessageRef]) async throws -> [GmailMessageSummary] {
        var summaries: [GmailMessageSummary] = []
        for ref in refs {
            var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(ref.id)")!
            var queryItems = [URLQueryItem(name: "format", value: "metadata")]
            for header in ["From", "To", "Subject", "Date"] {
                queryItems.append(URLQueryItem(name: "metadataHeaders", value: header))
            }
            components.queryItems = queryItems
            let detail = try await decode(GmailMessageDetail.self, from: components.url!)
            summaries.append(summaryFromDetail(detail))
        }
        return summaries
    }

    private func fetchMessageContent(id: String) async throws -> GmailMessageContent {
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)")!
        components.queryItems = [URLQueryItem(name: "format", value: "full")]
        let detail = try await decode(GmailMessageDetail.self, from: components.url!)
        return contentFromDetail(detail)
    }

    private func countUnreadInbox() async throws -> Int {
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "in:inbox is:unread"),
            URLQueryItem(name: "maxResults", value: "1")
        ]
        let list = try await decode(GmailMessageList.self, from: components.url!)
        return list.resultSizeEstimate ?? 0
    }

    private func summaryFromDetail(_ detail: GmailMessageDetail) -> GmailMessageSummary {
        let headers = headerMap(detail.payload?.headers ?? [])
        let labels = detail.labelIds ?? []
        return GmailMessageSummary(
            id: detail.id,
            threadId: detail.threadId,
            from: headers["from"] ?? "Unknown",
            to: headers["to"] ?? "Unknown",
            subject: headers["subject"] ?? "(No subject)",
            date: headers["date"] ?? "Unknown",
            snippet: detail.snippet ?? "",
            labelIds: labels,
            isUnread: labels.contains("UNREAD")
        )
    }

    private func contentFromDetail(_ detail: GmailMessageDetail) -> GmailMessageContent {
        let summary = summaryFromDetail(detail)
        let extracted = extractBody(from: detail.payload)
        let truncated = SecurityPolicy.truncateOutput(
            extracted.text,
            maxBytes: SecurityPolicy.maxGmailBodyBytes,
            suffix: "\n\n[BODY TRUNCATED AT \(SecurityPolicy.maxGmailBodyBytes) BYTES — DO NOT INFER MISSING CONTENT]"
        )
        return GmailMessageContent(
            summary: summary,
            body: truncated,
            bodyComplete: extracted.text.utf8.count <= SecurityPolicy.maxGmailBodyBytes,
            bodySource: extracted.source,
            attachments: extractAttachments(from: detail.payload)
        )
    }

    private func formatSummaries(_ summaries: [GmailMessageSummary], indexOnly: Bool) -> String {
        guard !summaries.isEmpty else { return "No messages found." }

        var lines: [String] = []
        for (index, item) in summaries.enumerated() {
            lines.append("""
            [\(index + 1)/\(summaries.count)] id=\(item.id) thread_id=\(item.threadId) unread=\(item.isUnread)
            from: \(item.from)
            to: \(item.to)
            subject: \(item.subject)
            date: \(item.date)
            labels: \(item.labelIds.joined(separator: ", "))
            snippet: \(item.snippet)
            """)
        }
        if indexOnly {
            lines.append("")
            lines.append("INDEX ONLY — call read_message, read_messages, or read_thread for full bodies before summarizing.")
        }
        return lines.joined(separator: "\n---\n")
    }

    private func formatMessageContent(_ content: GmailMessageContent, index: Int, total: Int) -> String {
        let s = content.summary
        var lines = [
            "[\(index)/\(total)] id=\(s.id) thread_id=\(s.threadId) unread=\(s.isUnread)",
            "from: \(s.from)",
            "to: \(s.to)",
            "subject: \(s.subject)",
            "date: \(s.date)",
            "labels: \(s.labelIds.joined(separator: ", "))",
            "body_source: \(content.bodySource)",
            "body_complete: \(content.bodyComplete)",
            "",
            "--- BODY ---",
            content.body.isEmpty ? "(Empty body)" : content.body
        ]
        if !content.attachments.isEmpty {
            lines.append("")
            lines.append("--- ATTACHMENTS (use read_attachment for text files) ---")
            for attachment in content.attachments {
                lines.append("- \(attachment.filename) (\(attachment.mimeType), \(attachment.size) bytes)\(attachment.attachmentId.map { ", id=\($0)" } ?? "")")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func indexWarnings() -> [String] {
        [
            "Results are an INDEX with snippets only.",
            "You MUST call read_message, read_messages, or read_thread before summarizing or quoting email content.",
            "Never invent message IDs — only use IDs from this output."
        ]
    }

    private func headerMap(_ headers: [GmailHeader]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: headers.map { ($0.name.lowercased(), $0.value) })
    }

    private struct BodyExtraction {
        let text: String
        let source: String
    }

    private func extractBody(from payload: GmailMessagePayload?) -> BodyExtraction {
        guard let payload else { return BodyExtraction(text: "", source: "none") }

        var plainParts: [String] = []
        collectPlainText(from: payload, into: &plainParts)

        if !plainParts.isEmpty {
            return BodyExtraction(text: plainParts.joined(separator: "\n\n"), source: "text/plain")
        }

        var htmlParts: [String] = []
        collectHTML(from: payload, into: &htmlParts)
        if !htmlParts.isEmpty {
            return BodyExtraction(text: htmlParts.map(stripHTML).joined(separator: "\n\n"), source: "text/html (converted)")
        }

        if let data = payload.body?.data, let text = decodeBase64URL(data) {
            return BodyExtraction(text: text, source: payload.mimeType ?? "unknown")
        }

        return BodyExtraction(text: "", source: "none")
    }

    private func collectPlainText(from payload: GmailMessagePayload, into parts: inout [String]) {
        if payload.mimeType == "text/plain", let data = payload.body?.data, let text = decodeBase64URL(data) {
            parts.append(text)
        }
        for part in payload.parts ?? [] {
            collectPlainText(from: part, into: &parts)
        }
    }

    private func collectHTML(from payload: GmailMessagePayload, into parts: inout [String]) {
        if payload.mimeType == "text/html", let data = payload.body?.data, let text = decodeBase64URL(data) {
            parts.append(text)
        }
        for part in payload.parts ?? [] {
            collectHTML(from: part, into: &parts)
        }
    }

    private func extractAttachments(from payload: GmailMessagePayload?) -> [GmailAttachmentInfo] {
        guard let payload else { return [] }
        var attachments: [GmailAttachmentInfo] = []
        collectAttachments(from: payload, into: &attachments)
        return attachments
    }

    private func collectAttachments(from payload: GmailMessagePayload, into attachments: inout [GmailAttachmentInfo]) {
        if let filename = payload.filename, !filename.isEmpty,
           payload.body?.attachmentId != nil || (payload.body?.size ?? 0) > 0 {
            attachments.append(GmailAttachmentInfo(
                filename: filename,
                mimeType: payload.mimeType ?? "application/octet-stream",
                size: payload.body?.size ?? 0,
                attachmentId: payload.body?.attachmentId
            ))
        }
        for part in payload.parts ?? [] {
            collectAttachments(from: part, into: &attachments)
        }
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

    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
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

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await performRequest(request)
        guard response.statusCode == 200 else {
            throw GmailAuthError.networkError(String(data: data, encoding: .utf8) ?? "HTTP \(response.statusCode)")
        }
        return try JSONDecoder().decode(type, from: data)
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var current = request
        var delay: UInt64 = 500_000_000

        for attempt in 0..<SecurityPolicy.gmailMaxRetries {
            let (data, response) = try await URLSession.shared.data(for: current)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw GmailAuthError.networkError("Invalid response.")
            }

            if httpResponse.statusCode == 429 || (500...599).contains(httpResponse.statusCode) {
                if attempt < SecurityPolicy.gmailMaxRetries - 1 {
                    try await Task.sleep(nanoseconds: delay)
                    delay *= 2
                    continue
                }
            }

            return (data, httpResponse)
        }

        throw GmailAuthError.networkError("Request failed after retries.")
    }
}

// MARK: - API Models

private struct GmailProfileDetail: Decodable {
    let emailAddress: String
    let messagesTotal: Int
    let threadsTotal: Int
    let historyId: String
}

private struct GmailMessageList: Decodable {
    let messages: [GmailMessageRef]?
    let nextPageToken: String?
    let resultSizeEstimate: Int?
}

private struct GmailMessageRef: Decodable {
    let id: String
}

private struct GmailThreadDetail: Decodable {
    let messages: [GmailMessageDetail]?
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
    let filename: String?
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
    let size: Int?
    let attachmentId: String?
}

private struct GmailSendResponse: Decodable {
    let id: String
}

private struct GmailAttachmentBody: Decodable {
    let data: String?
    let size: Int?
}
