//
//  GmailService.swift
//  zoro
//
//  Gmail REST client used by GmailMailProvider (manage_mail path).
//

import Foundation

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

struct GmailService: Sendable {
    let accountId: UUID
    let accessToken: String

    static func makeAuthenticated(accountId: UUID) async throws -> GmailService {
        let token = try await GmailAuthManager.shared.getValidAccessToken(accountId: accountId)
        return GmailService(accountId: accountId, accessToken: token)
    }

    // MARK: - Read / search (MailProvider)

    func fetchUnreadSummaries(
        limit: Int,
        pageToken: String? = nil
    ) async throws -> (summaries: [GmailMessageSummary], fetchComplete: Bool, nextPageToken: String?) {
        let page = try await fetchMessageRefs(
            query: "in:inbox is:unread",
            labelIds: nil,
            pageToken: pageToken,
            maxResults: min(limit, SecurityPolicy.gmailPageSize),
            hardCap: limit
        )
        let summaries = try await fetchSummaries(for: page.refs)
        return (summaries, page.fetchComplete, page.nextPageToken)
    }

    func searchSummaries(
        query: String,
        limit: Int,
        pageToken: String? = nil
    ) async throws -> (summaries: [GmailMessageSummary], fetchComplete: Bool, nextPageToken: String?) {
        let page = try await fetchMessageRefs(
            query: query,
            labelIds: nil,
            pageToken: pageToken,
            maxResults: min(limit, SecurityPolicy.gmailPageSize),
            hardCap: limit
        )
        let summaries = try await fetchSummaries(for: page.refs)
        return (summaries, page.fetchComplete, page.nextPageToken)
    }

    func fetchMessageContent(id: String) async throws -> GmailMessageContent {
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)")!
        components.queryItems = [URLQueryItem(name: "format", value: "full")]
        let detail = try await decode(GmailMessageDetail.self, from: components.url!)
        return contentFromDetail(detail)
    }

    // MARK: - Mutations used by MailProvider

    func markMessageAsRead(id: String) async throws -> String {
        try await modifyMessageLabels(id: id, add: [], remove: ["UNREAD"])
        return "Successfully marked message \(id) as read."
    }

    func archiveMessage(id: String) async throws -> String {
        try await modifyMessageLabels(id: id, add: [], remove: ["INBOX"])
        return "Successfully archived message \(id) (removed from INBOX)."
    }

    func createDraftRecord(
        to: String,
        subject: String,
        body: String,
        cc: String?,
        bcc: String?,
        threadId: String?
    ) async throws -> (draftId: String, messageId: String) {
        let rawMessage = buildRawEmail(to: to, subject: subject, body: body, cc: cc, bcc: bcc)
        let encoded = GmailParsing.base64URLEncode(Data(rawMessage.utf8))
        var messagePayload: [String: Any] = ["raw": encoded]
        if let threadId { messagePayload["threadId"] = threadId }

        var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/drafts")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["message": messagePayload])

        let (data, response) = try await performRequest(request)
        guard response.statusCode == 200 else {
            throw GmailAuthError.networkError("Create draft failed: \(String(data: data, encoding: .utf8) ?? "Unknown error")")
        }
        let draft = try JSONDecoder().decode(GmailDraftResponse.self, from: data)
        return (draft.id, draft.message.id)
    }

    func sendDraft(draftId: String) async throws {
        var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/drafts/\(draftId)/send")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await performRequest(request)
        guard response.statusCode == 200 else {
            throw GmailAuthError.networkError("Send draft failed: \(String(data: data, encoding: .utf8) ?? "Unknown error")")
        }
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

    private func modifyMessageLabels(id: String, add: [String], remove: [String]) async throws {
        var payload: [String: Any] = [:]
        if !add.isEmpty { payload["addLabelIds"] = add }
        if !remove.isEmpty { payload["removeLabelIds"] = remove }
        guard !payload.isEmpty else {
            throw GmailAuthError.networkError("No label changes specified.")
        }

        var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)/modify")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await performRequest(request)
        guard response.statusCode == 200 else {
            throw GmailAuthError.networkError("Label modify failed: \(String(data: data, encoding: .utf8) ?? "Unknown error")")
        }
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
            return BodyExtraction(text: htmlParts.map(GmailParsing.stripHTML).joined(separator: "\n\n"), source: "text/html (converted)")
        }

        if let data = payload.body?.data, let text = GmailParsing.decodeBase64URL(data) {
            return BodyExtraction(text: text, source: payload.mimeType ?? "unknown")
        }

        return BodyExtraction(text: "", source: "none")
    }

    private func collectPlainText(from payload: GmailMessagePayload, into parts: inout [String]) {
        if payload.mimeType == "text/plain", let data = payload.body?.data, let text = GmailParsing.decodeBase64URL(data) {
            parts.append(text)
        }
        for part in payload.parts ?? [] {
            collectPlainText(from: part, into: &parts)
        }
    }

    private func collectHTML(from payload: GmailMessagePayload, into parts: inout [String]) {
        if payload.mimeType == "text/html", let data = payload.body?.data, let text = GmailParsing.decodeBase64URL(data) {
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
        var delay: UInt64 = 500_000_000

        for attempt in 0..<SecurityPolicy.gmailMaxRetries {
            let (data, response) = try await URLSession.shared.data(for: request)
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

private struct GmailMessageList: Decodable {
    let messages: [GmailMessageRef]?
    let nextPageToken: String?
    let resultSizeEstimate: Int?
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

private struct GmailDraftResponse: Decodable {
    let id: String
    let message: GmailDraftMessage
}

private struct GmailDraftMessage: Decodable {
    let id: String
}
