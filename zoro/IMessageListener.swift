//
//  IMessageListener.swift
//  zoro
//
//  Created by AI Agent on 22/06/26.
//

import Foundation
import SQLite3
import Combine
import FoundationModels

class IMessageListener {
    static let shared = IMessageListener()

    private var fileDescriptor: Int32 = -1
    private var dispatchSource: DispatchSourceFileSystemObject?
    private var fallbackTimer: Timer?

    private var lastRowId: Int64 = 0
    private var isListening = false

    private var requestTimestampsBySender: [String: [Date]] = [:]

    private var dbPath: String {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        return homeDir.appendingPathComponent("Library/Messages/chat.db").path
    }

    private init() {}

    func start() {
        guard !isListening else { return }

        self.lastRowId = getMaxRowId()
        isListening = true

        fileDescriptor = open(dbPath, O_EVTONLY)
        if fileDescriptor >= 0 {
            let queue = DispatchQueue(label: "com.zoro.imessagelistener", qos: .background)
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fileDescriptor,
                eventMask: .write,
                queue: queue
            )

            source.setEventHandler { [weak self] in
                self?.checkForNewMessages()
            }

            source.setCancelHandler { [weak self] in
                if let fd = self?.fileDescriptor {
                    close(fd)
                }
            }

            dispatchSource = source
            source.resume()
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.fallbackTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
                self?.checkForNewMessages()
            }
        }

        print("iMessage listener started. Current Max RowID: \(lastRowId)")
    }

    func stop() {
        guard isListening else { return }
        isListening = false

        dispatchSource?.cancel()
        dispatchSource = nil
        fileDescriptor = -1

        DispatchQueue.main.async {
            self.fallbackTimer?.invalidate()
            self.fallbackTimer = nil
        }

        print("iMessage listener stopped.")
    }

    private func getMaxRowId() -> Int64 {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return 0
        }
        defer { sqlite3_close(db) }

        let query = "SELECT MAX(ROWID) FROM message;"
        var statement: OpaquePointer?

        var maxId: Int64 = 0
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                maxId = sqlite3_column_int64(statement, 0)
            }
        }
        sqlite3_finalize(statement)
        return maxId
    }

    private func checkForNewMessages() {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return
        }
        defer { sqlite3_close(db) }

        let query = """
        SELECT m.rowid, m.text, m.attributedBody, h.id, a.filename
        FROM message m
        LEFT JOIN handle h ON m.handle_id = h.rowid
        LEFT JOIN message_attachment_join maj ON maj.message_id = m.rowid
        LEFT JOIN attachment a ON a.rowid = maj.attachment_id
        WHERE m.rowid > ? AND m.is_from_me = 0
        ORDER BY m.rowid ASC;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, lastRowId)

        struct RowData {
            let rowid: Int64
            let text: String?
            let attributedBody: Data?
            let sender: String?
            var attachments: [String]
        }

        var messagesMap: [Int64: RowData] = [:]
        var order: [Int64] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            let rowid = sqlite3_column_int64(statement, 0)

            var text: String? = nil
            if let textPtr = sqlite3_column_text(statement, 1) {
                text = String(cString: textPtr)
            }

            var attributedBody: Data? = nil
            let blobLength = sqlite3_column_bytes(statement, 2)
            if blobLength > 0, let blobBytes = sqlite3_column_blob(statement, 2) {
                attributedBody = Data(bytes: blobBytes, count: Int(blobLength))
            }

            var sender: String? = nil
            if let senderPtr = sqlite3_column_text(statement, 3) {
                sender = String(cString: senderPtr)
            }

            var attachmentPath: String? = nil
            if let attachPtr = sqlite3_column_text(statement, 4) {
                attachmentPath = String(cString: attachPtr)
            }

            if var existing = messagesMap[rowid] {
                if let path = attachmentPath {
                    existing.attachments.append(path)
                }
                messagesMap[rowid] = existing
            } else {
                var attachments: [String] = []
                if let path = attachmentPath {
                    attachments.append(path)
                }
                messagesMap[rowid] = RowData(
                    rowid: rowid,
                    text: text,
                    attributedBody: attributedBody,
                    sender: sender,
                    attachments: attachments
                )
                order.append(rowid)
            }
        }

        for rowid in order {
            guard let msg = messagesMap[rowid] else { continue }
            self.lastRowId = max(self.lastRowId, rowid)

            var bodyText = msg.text
            if (bodyText == nil || bodyText!.isEmpty), let bodyData = msg.attributedBody {
                bodyText = extractText(from: bodyData)
            }

            if let content = bodyText {
                processIncomingMessage(sender: msg.sender ?? "", text: content, attachments: msg.attachments)
            }
        }
    }

    private func extractText(from data: Data) -> String? {
        if let attrStr = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: data) {
            return attrStr.string
        }

        var printableBytes = [UInt8]()
        var bestString = ""

        for byte in data {
            if (byte >= 32 && byte <= 126) || byte == 10 || byte == 13 || byte == 9 {
                printableBytes.append(byte)
            } else {
                if printableBytes.count >= 2 {
                    if let str = String(bytes: printableBytes, encoding: .utf8) {
                        if !str.contains("NSString") && !str.contains("NSDictionary") && !str.contains("NSAttribute") && !str.contains("NSMutable") && !str.contains("NSColor") && !str.contains("NSFont") && !str.contains("NSParagraphStyle") {
                            if str.count > bestString.count {
                                bestString = str
                            }
                        }
                    }
                }
                printableBytes.removeAll()
            }
        }
        if printableBytes.count >= 2 {
            if let str = String(bytes: printableBytes, encoding: .utf8) {
                if !str.contains("NSString") && str.count > bestString.count {
                    bestString = str
                }
            }
        }

        return bestString.isEmpty ? nil : bestString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func processIncomingMessage(sender: String, text: String, attachments: [String]) {
        let defaults = UserDefaults.standard
        let isEnabled = defaults.bool(forKey: "imessage_listener_enabled")
        let whitelist = defaults.string(forKey: "imessage_sender_whitelist") ?? ""

        guard isEnabled else { return }
        guard SecurityPolicy.isSenderWhitelisted(sender, whitelist: whitelist) else { return }

        let prefix = "zoro:"
        guard text.lowercased().hasPrefix(prefix) else { return }

        let savedPasscode = KeychainHelper.retrieve(key: "imessage_passcode") ?? ""
        guard !savedPasscode.isEmpty else {
            sendReply(to: sender, text: "🔒 Access Denied: Configure an iMessage passcode in Zoro settings before using remote commands.")
            return
        }

        if isRateLimited(for: sender) {
            sendReply(to: sender, text: "⚠️ Zoro Rate Limit Exceeded: Please wait a moment before sending more commands.")
            return
        }

        let remainingText = text.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)

        let parts = remainingText.components(separatedBy: .whitespacesAndNewlines)
        guard let first = parts.first, first == savedPasscode else {
            sendReply(to: sender, text: "🔒 Access Denied: Incorrect passcode.")
            return
        }
        let commandText = parts.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

        guard !commandText.isEmpty else { return }

        var finalPrompt = commandText
        for path in attachments {
            guard let url = SecurityPolicy.resolveIMessageAttachmentPath(path) else {
                finalPrompt += "\n\n[Attachment skipped: path is outside the Messages attachments directory]"
                continue
            }

            let filename = url.lastPathComponent
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0

            if isTextFile(url) {
                if fileSize > SecurityPolicy.maxIMessageAttachmentBytes {
                    finalPrompt += "\n\n[Attachment: \(filename) (Text file, \(fileSize) bytes) is too large to read entirely.]"
                } else if let fileContent = try? String(contentsOf: url, encoding: .utf8) {
                    finalPrompt += "\n\n[Attachment: \(filename)]\n```\n\(fileContent)\n```"
                }
            } else {
                finalPrompt += "\n\n[Attachment: \(filename) (Binary file, \(fileSize) bytes) cannot be read as text.]"
            }
        }

        Task {
            await runZoroAgent(sender: sender, prompt: finalPrompt)
        }
    }

    private func isTextFile(_ url: URL) -> Bool {
        let textExtensions = ["txt", "swift", "py", "js", "html", "css", "json", "md", "log", "xml", "yaml", "yml", "sh", "c", "h", "cpp", "go", "rs", "plist"]
        return textExtensions.contains(url.pathExtension.lowercased())
    }

    private func isRateLimited(for sender: String) -> Bool {
        let normalizedSender = SecurityPolicy.normalizeContact(sender)
        let now = Date()
        var timestamps = requestTimestampsBySender[normalizedSender] ?? []
        timestamps = timestamps.filter { now.timeIntervalSince($0) < 60 }

        if timestamps.count >= SecurityPolicy.iMessageRateLimitPerMinute {
            requestTimestampsBySender[normalizedSender] = timestamps
            return true
        }

        timestamps.append(now)
        requestTimestampsBySender[normalizedSender] = timestamps
        return false
    }

    private func runZoroAgent(sender: String, prompt: String) async {
        await MainActor.run {
            GmailReadAuditor.resetPromptState()
        }
        do {
            let workspace = await WorkspaceManager.shared
            let activeSession = try workspace.getOrCreateSession(context: .iMessage(requester: sender))
            let stream = activeSession.streamResponse(to: prompt)

            var finalReply = ""
            for try await chunk in stream {
                finalReply = chunk.content
            }

            if !finalReply.isEmpty {
                let audited = await MainActor.run {
                    GmailReadAuditor.auditAssistantResponse(finalReply, userPrompt: prompt)
                }
                let truncatedReply = truncateReply(audited)
                sendReply(to: sender, text: truncatedReply)
            } else {
                await MainActor.run {
                    WorkspaceManager.shared.finishRemoteExecution()
                }
            }
        } catch {
            sendReply(to: sender, text: "⚠️ Error running Zoro agent: \(error.localizedDescription)")
        }
    }

    private func truncateReply(_ text: String) -> String {
        guard text.count > SecurityPolicy.maxIMessageReplyCharacters else { return text }
        let endIndex = text.index(text.startIndex, offsetBy: SecurityPolicy.maxIMessageReplyCharacters)
        return String(text[..<endIndex]) + "\n\n[Reply truncated]"
    }

    private func sendReply(to recipient: String, text: String) {
        Task { @MainActor in
            WorkspaceManager.shared.finishRemoteExecution()
            let tool = IMessageTool()
            let args = IMessageTool.Arguments(recipient: recipient, text: text, service: "auto")
            _ = try? await tool.call(arguments: args)
        }
    }
}
