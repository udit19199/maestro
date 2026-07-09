//
//  MailManager.swift
//  zoro
//
//  @MainActor orchestrator: unified sync, priority ranking, session read tracking, activity log.
//

import Foundation
import Combine
import os

enum MailAccountSyncStatus: Equatable, Sendable {
    case idle
    case syncing
    case ok(unreadCount: Int)
    case error(String)
}

struct MailAccountResolutionFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

@MainActor
final class MailManager: ObservableObject {
    static let shared = MailManager()

    struct ActivityEntry: Identifiable, Equatable {
        let id = UUID()
        let message: String
        var status: String
        let timestamp: Date
    }

    @Published private(set) var priorityUnread: [BriefingMailItem] = []
    @Published private(set) var inboxUnreadTotal = 0
    @Published private(set) var pendingCleanupCount = 0
    @Published private(set) var syncStatus: [UUID: MailAccountSyncStatus] = [:]
    @Published private(set) var activityLog: [ActivityEntry] = []
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var isSyncing = false
    @Published private(set) var lastError: String?

    private(set) var allUnreadSummaries: [MailMessageSummary] = []
    private(set) var sessionReadKeys: Set<String> = []

    private var autoRefreshTimer: Timer?
    private let logger = Logger(subsystem: "com.zoro.mail", category: "MailManager")

    private init() {}

    // MARK: - Provider factory

    func makeProvider(for account: MailAccount) -> (any MailProvider)? {
        guard account.isEnabled else { return nil }
        switch account.provider {
        case .gmail:
            guard MailAccountKeychain.gmailRefreshToken(for: account.id) != nil else { return nil }
            return GmailMailProvider(accountId: account.id)
        case .imap:
            guard MailAccountKeychain.imapPassword(for: account.id) != nil else { return nil }
            return try? IMAPMailProvider(account: account)
        }
    }

    func configuredAccounts() -> [MailAccount] {
        MailAccountStore.shared.enabledAccounts.filter { makeProvider(for: $0) != nil }
    }

    func resolveAccount(accountId: String?, accountEmail: String?) -> MailAccount? {
        let store = MailAccountStore.shared
        if let raw = accountId?.trimmingCharacters(in: .whitespacesAndNewlines),
           let uuid = UUID(uuidString: raw),
           let account = store.account(id: uuid) {
            return account
        }
        if let raw = accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let lower = raw.lowercased()
            return store.accounts.first { $0.email.lowercased() == lower }
        }
        return nil
    }

    func resolveProvider(accountId: String?, accountEmail: String?, requireAccount: Bool) -> Result<(any MailProvider, MailAccount), MailAccountResolutionFailure> {
        if let account = resolveAccount(accountId: accountId, accountEmail: accountEmail) {
            guard let provider = makeProvider(for: account) else {
                return .failure(MailAccountResolutionFailure(message: "Error: Account '\(account.accountLabel)' is not connected or missing credentials."))
            }
            return .success((provider, account))
        }

        let configured = configuredAccounts()
        if configured.count == 1, let account = configured.first, let provider = makeProvider(for: account) {
            return .success((provider, account))
        }

        if requireAccount || configured.count > 1 {
            return .failure(MailAccountResolutionFailure(message: "Error: account_id or account_email is required when multiple mail accounts are connected."))
        }

        return .failure(MailAccountResolutionFailure(message: "Error: No mail accounts connected."))
    }

    func allProviders() -> [(provider: any MailProvider, account: MailAccount)] {
        configuredAccounts().compactMap { account in
            guard let provider = makeProvider(for: account) else { return nil }
            return (provider, account)
        }
    }

    // MARK: - Sync

    func syncAllAccounts(limitPerAccount: Int = 50) async {
        let accounts = configuredAccounts()
        guard !accounts.isEmpty else {
            allUnreadSummaries = []
            priorityUnread = []
            inboxUnreadTotal = 0
            pendingCleanupCount = 0
            syncStatus = [:]
            lastSyncedAt = nil
            stopAutoRefresh()
            return
        }

        isSyncing = true
        lastError = nil
        for account in accounts {
            syncStatus[account.id] = .syncing
        }

        let providers = allProviders().map(\.provider)
        let outcomes = await MailSyncActor.shared.syncAccounts(providers: providers, limitPerAccount: limitPerAccount)

        var merged: [MailMessageSummary] = []
        var statusMap: [UUID: MailAccountSyncStatus] = [:]

        for outcome in outcomes {
            if let error = outcome.error {
                statusMap[outcome.accountId] = .error(error.localizedDescription)
                logger.error("Sync failed for \(outcome.accountId.uuidString): \(error.localizedDescription, privacy: .public)")
            } else if let unread = outcome.unread {
                statusMap[outcome.accountId] = .ok(unreadCount: unread.summaries.filter(\.isUnread).count)
                merged.append(contentsOf: unread.summaries)
            } else {
                statusMap[outcome.accountId] = .idle
            }
        }

        allUnreadSummaries = merged
        inboxUnreadTotal = merged.filter(\.isUnread).count
        pendingCleanupCount = merged.filter { CleanupHeuristics.isCleanupCandidate($0) }.count

        let labels = MailAccountStore.shared.accountLabelsByID()
        priorityUnread = MailPriorityRanker.topBriefingItems(from: merged, accountLabels: labels)

        syncStatus = statusMap
        lastSyncedAt = Date()
        isSyncing = false
        startAutoRefreshIfNeeded()
    }

    func refreshSnapshot() async {
        await syncAllAccounts(limitPerAccount: 50)
    }

    /// Sends a user-confirmed draft from `pendingMailSend`.
    func confirmPendingSend(_ request: PendingMailSendRequest) async throws {
        guard let account = MailAccountStore.shared.account(id: request.accountId),
              let provider = makeProvider(for: account) else {
            throw MailError.authenticationFailed(
                accountId: request.accountId,
                detail: "Account is not connected or missing credentials."
            )
        }

        try await MailSyncActor.shared.send(from: provider, draftId: request.draftId)
        logActivity("Sent email to \(request.to)", status: "completed")
    }

    // MARK: - Session read tracking

    static func readKey(accountId: UUID, messageId: String) -> String {
        "\(accountId.uuidString)|\(messageId)"
    }

    func recordMessagesRead(accountId: UUID, messageIds: [String]) {
        for id in messageIds where !id.isEmpty {
            sessionReadKeys.insert(Self.readKey(accountId: accountId, messageId: id))
        }
    }

    func sessionReadFooter() -> String {
        if sessionReadKeys.isEmpty {
            return "session_messages_fully_read: none"
        }
        let listed = sessionReadKeys.sorted().joined(separator: ", ")
        return "session_messages_fully_read: \(listed)"
    }

    func clearSessionReads() {
        sessionReadKeys = []
    }

    func isMessageFullyRead(accountId: UUID, messageId: String) -> Bool {
        sessionReadKeys.contains(Self.readKey(accountId: accountId, messageId: messageId))
    }

    // MARK: - Auto refresh

    func startAutoRefreshIfNeeded() {
        stopAutoRefresh()
        guard !configuredAccounts().isEmpty else { return }
        autoRefreshTimer = Timer.scheduledTimer(withTimeInterval: SecurityPolicy.gmailAutoRefreshSeconds, repeats: true) { [weak self] _ in
            Task { await self?.syncAllAccounts() }
        }
    }

    func stopAutoRefresh() {
        autoRefreshTimer?.invalidate()
        autoRefreshTimer = nil
    }

    // MARK: - Activity log

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

    // MARK: - Agent context

    func contextualInstructions() -> String? {
        let accounts = configuredAccounts()
        guard !accounts.isEmpty else { return nil }

        let accountLines = accounts.map { account in
            let unread = syncStatus[account.id].flatMap { status -> String? in
                if case .ok(let count) = status { return String(count) }
                return nil
            } ?? "unknown"
            return "- \(account.accountLabel) (\(account.email.isEmpty ? account.provider.rawValue : account.email)): \(unread) unread"
        }.joined(separator: "\n")

        let synced = lastSyncedAt.map {
            DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short)
        } ?? "not yet synced"

        return """
        === MAIL (MULTI-INBOX INTEGRATION) ===
        Connected accounts:
        \(accountLines)
        Total unread (last sync): \(inboxUnreadTotal)
        Last inbox sync: \(synced)

        The user relies on email across these accounts. These rules are mandatory:
        1. NEVER invent, guess, or extrapolate email content, subjects, senders, dates, or message IDs.
        2. list_unread and search return an INDEX with snippets only — NEVER summarize or quote email bodies from snippets.
        3. Before answering questions about email content, ALWAYS call read_message using IDs from tool output.
        4. When multiple accounts are connected, pass account_id or account_email for write actions (archive, draft, send).
        5. If fetch_complete is false, fetch remaining pages before concluding how many emails match.
        6. When body_complete is false, state the truncation explicitly — do NOT fill in missing content.
        7. Cite message IDs and account_id when referencing specific emails.
        8. Call get_status when you need current unread counts or account confirmation.
        9. send_email and reply_to_message create a draft only — they return pending_send_id for user confirmation; never claim an email was sent until confirmed.
        10. Only cite messages listed in session_messages_fully_read when summarizing content — if not listed, call read_message first.
        === END MAIL RULES ===
        """
    }
}
