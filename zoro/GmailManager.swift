//
//  GmailManager.swift
//  zoro
//
//  First-class Gmail state: inbox snapshot, activity log, and agent context injection.
//

import Foundation
import Combine

@MainActor
final class GmailManager: ObservableObject {
    static let shared = GmailManager()

    struct InboxPreviewItem: Identifiable, Equatable {
        let id: String
        let from: String
        let subject: String
        let date: String
        let isUnread: Bool
    }

    struct ActivityEntry: Identifiable, Equatable {
        let id = UUID()
        let message: String
        var status: String
        let timestamp: Date
    }

    @Published var unreadCount: Int?
    @Published var inboxPreview: [InboxPreviewItem] = []
    @Published var activityLog: [ActivityEntry] = []
    @Published var lastSyncedAt: Date?
    @Published var isSyncing: Bool = false
    @Published var syncError: String?

    private(set) var sessionReadMessageIds: Set<String> = []
    private var autoRefreshTimer: Timer?

    private init() {}

    func refreshSnapshot() async {
        guard GmailAuthManager.shared.isConnected else {
            stopAutoRefresh()
            unreadCount = nil
            inboxPreview = []
            lastSyncedAt = nil
            syncError = nil
            return
        }

        isSyncing = true
        syncError = nil
        defer { isSyncing = false }

        do {
            let service = try await GmailService.makeAuthenticated()
            let status = try await service.fetchStatus()
            unreadCount = status.unreadInbox

            let preview = try await service.fetchInboxPreview(maxItems: 8)
            inboxPreview = preview.map { item in
                InboxPreviewItem(
                    id: item.id,
                    from: item.from,
                    subject: item.subject,
                    date: item.date,
                    isUnread: item.isUnread
                )
            }
            lastSyncedAt = Date()
            startAutoRefreshIfNeeded()
        } catch {
            syncError = error.localizedDescription
        }
    }

    func recordMessagesRead(_ ids: [String]) {
        sessionReadMessageIds.formUnion(ids.filter { !$0.isEmpty })
    }

    func sessionReadFooter() -> String {
        if sessionReadMessageIds.isEmpty {
            return "session_messages_fully_read: none"
        }
        let listed = sessionReadMessageIds.sorted().joined(separator: ", ")
        return "session_messages_fully_read: \(listed)"
    }

    func clearSessionReads() {
        sessionReadMessageIds = []
    }

    func startAutoRefreshIfNeeded() {
        stopAutoRefresh()
        guard GmailAuthManager.shared.isConnected else { return }
        autoRefreshTimer = Timer.scheduledTimer(withTimeInterval: SecurityPolicy.gmailAutoRefreshSeconds, repeats: true) { [weak self] _ in
            Task { await self?.refreshSnapshot() }
        }
    }

    func stopAutoRefresh() {
        autoRefreshTimer?.invalidate()
        autoRefreshTimer = nil
    }

    func logActivity(_ message: String, status: String = "in_progress") {
        activityLog.append(ActivityEntry(message: message, status: status, timestamp: Date()))
        if activityLog.count > 20 {
            activityLog.removeFirst(activityLog.count - 20)
        }
    }

    func completeActivity(matching prefix: String) {
        if let index = activityLog.lastIndex(where: { $0.message.hasPrefix(prefix) && $0.status == "in_progress" }) {
            activityLog[index].status = "completed"
        }
    }

    func failActivity(matching prefix: String) {
        if let index = activityLog.lastIndex(where: { $0.message.hasPrefix(prefix) && $0.status == "in_progress" }) {
            activityLog[index].status = "failed"
        }
    }

    func clearActivity() {
        activityLog = []
    }

    func contextualInstructions() -> String? {
        guard GmailAuthManager.shared.isConnected else { return nil }

        let email = GmailAuthManager.shared.connectedEmail ?? "connected account"
        let unread = unreadCount.map { String($0) } ?? "unknown"
        let synced = lastSyncedAt.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short) } ?? "not yet synced"

        return """
        === GMAIL (FIRST-CLASS INTEGRATION) ===
        Connected account: \(email)
        Unread inbox messages: \(unread)
        Last inbox sync: \(synced)

        The user relies heavily on Gmail. These rules are mandatory:
        1. NEVER invent, guess, or extrapolate email content, subjects, senders, dates, thread IDs, or message IDs.
        2. list_messages and search_messages return an INDEX with snippets only — NEVER summarize or quote email bodies from snippets.
        3. Before answering questions about email content, ALWAYS call read_message, read_messages, or read_thread using IDs from tool output.
        4. When the user asks about a conversation, prefer read_thread over read_message.
        5. If fetch_complete is false, fetch remaining pages (fetchAll: true or pageToken) before concluding how many emails match.
        6. When body_complete is false, state the truncation explicitly — do NOT fill in missing content.
        7. Cite message IDs when referencing specific emails.
        8. Call get_status when you need current unread counts or account confirmation.
        9. Use read_attachment for text attachments (plain, HTML, JSON, CSV) when the body references an attachment.
        10. Only cite message IDs listed in session_messages_fully_read when summarizing content — if an ID is not listed, call read_message first.
        === END GMAIL RULES ===
        """
    }
}
