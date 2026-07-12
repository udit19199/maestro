//
//  BriefingService.swift
//  zoro
//

import Foundation
import Combine
import EventKit

@MainActor
final class BriefingService: ObservableObject {
    static let shared = BriefingService()

    @Published private(set) var yesterdayRecap = "No recap yet — your briefing will populate as you use Zoro."
    @Published private(set) var todayCalendarSummary = "Loading calendar…"
    @Published private(set) var suggestions: [String] = []
    @Published private(set) var inboxDigest = ""
    @Published private(set) var priorityUnread: [BriefingMailItem] = []
    @Published private(set) var inboxUnreadTotal = 0
    @Published private(set) var pendingCleanupCount = 0
    @Published private(set) var pendingCalendarProposalCount = 0
    @Published private(set) var inboxState: BriefingInboxState = .loading
    @Published private(set) var lastRefreshedAt: Date?
    @Published private(set) var isRefreshing = false

    /// Syncs inbox from MailManager; digest uses Foundation Models when available, else template fallback.
    private func refreshInboxSection() async {
        let mail = MailManager.shared
        let accounts = mail.configuredAccounts()

        guard !accounts.isEmpty else {
            inboxState = .noAccounts
            inboxDigest = ""
            priorityUnread = []
            inboxUnreadTotal = 0
            pendingCleanupCount = 0
            return
        }

        inboxState = .loading
        await mail.syncAllAccounts(limitPerAccount: 50)

        if let error = mail.lastError {
            inboxState = .error(message: error)
        } else if mail.priorityUnread.isEmpty && mail.inboxUnreadTotal == 0 {
            inboxState = .empty(message: "No unread mail across your connected accounts.")
        } else {
            inboxState = .loaded
        }

        priorityUnread = mail.priorityUnread
        inboxUnreadTotal = mail.inboxUnreadTotal
        pendingCleanupCount = mail.pendingCleanupCount

        let calendarProposals = await EmailCalendarDetector.scanForProposals(
            summaries: mail.allUnreadSummaries,
            providers: mail.allProviders()
        )
        if !calendarProposals.isEmpty {
            mergeCalendarProposals(calendarProposals)
        }
        pendingCalendarProposalCount = WorkspaceManager.shared.pendingCalendarProposals.count

        var digest = BriefingMailDigestGenerator.generate(from: mail.allUnreadSummaries)
        if pendingCalendarProposalCount > 0 {
            let suffix = " · \(pendingCalendarProposalCount) event\(pendingCalendarProposalCount == 1 ? "" : "s") to confirm"
            if !digest.contains("to confirm") {
                digest += suffix
            }
        }
        inboxDigest = digest
    }

    /// Keeps cleanup CTA count in sync when CleanupReviewService scans outside a full briefing refresh.
    func syncPendingCleanupCount(_ count: Int) {
        pendingCleanupCount = count
    }

    private func mergeCalendarProposals(_ detected: [PlannerEventProposal]) {
        var merged = WorkspaceManager.shared.pendingCalendarProposals
        for proposal in detected {
            let duplicate = merged.contains {
                $0.title == proposal.title && $0.startDate == proposal.startDate
            }
            if !duplicate {
                merged.append(proposal)
            }
        }
        WorkspaceManager.shared.setPendingCalendarProposals(merged)
    }
    private var defaultsKey: String { "briefing_refresh_interval_hours" }

    var refreshIntervalHours: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: defaultsKey)
            return stored > 0 ? stored : 3
        }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKey)
            restartBackgroundTimer()
        }
    }

    private init() {}

    func startBackgroundRefresh() {
        restartBackgroundTimer()
    }

    func stopBackgroundRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refresh(conversationStore: ConversationStore? = nil) async {
        // Default args cannot reference MainActor `.shared` (evaluated nonisolated).
        let conversationStore = conversationStore ?? .shared

        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        yesterdayRecap = buildYesterdayRecap(conversations: conversationStore.conversations)
        todayCalendarSummary = await fetchTodayCalendarSummary()
        suggestions = buildSuggestions(
            conversations: conversationStore.conversations,
            profile: ProfileStore.shared.profile
        )
        await refreshInboxSection()
        lastRefreshedAt = Date()
    }

    private var refreshTimer: Timer?

    private func restartBackgroundTimer() {
        refreshTimer?.invalidate()
        let interval = refreshIntervalHours * 3600
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
    }

    private func buildYesterdayRecap(conversations: [Conversation]) -> String {
        let calendar = Calendar.current
        guard let startOfToday = calendar.dateInterval(of: .day, for: Date())?.start,
              let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) else {
            return "No activity recorded yesterday."
        }

        let yesterdayChats = conversations.filter { conversation in
            conversation.source == .desktop &&
            conversation.updatedAt >= startOfYesterday &&
            conversation.updatedAt < startOfToday &&
            conversation.messages.count > 1
        }

        guard !yesterdayChats.isEmpty else {
            return "No Zoro conversations yesterday. A quiet day."
        }

        var lines: [String] = []
        lines.append("You had \(yesterdayChats.count) conversation\(yesterdayChats.count == 1 ? "" : "s") yesterday:")

        for conversation in yesterdayChats.prefix(5) {
            let agentLabel = conversation.agentType.displayName
            let lastUserMessage = conversation.messages.last(where: { $0.role == .user })?.content ?? conversation.title
            let snippet = Self.snippet(from: lastUserMessage, maxLength: 80)
            lines.append("• \(agentLabel): \(snippet)")
        }

        if yesterdayChats.count > 5 {
            lines.append("• …and \(yesterdayChats.count - 5) more")
        }

        return lines.joined(separator: "\n")
    }

    private func fetchTodayCalendarSummary() async -> String {
        let store = EKEventStore()
        let calendarGranted: Bool
        if #available(macOS 14.0, *) {
            calendarGranted = (try? await store.requestFullAccessToEvents()) ?? false
        } else {
            calendarGranted = await withCheckedContinuation { continuation in
                store.requestAccess(to: .event) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        }

        guard calendarGranted else {
            return "Calendar access not granted. Enable in System Settings to see today's schedule."
        }

        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        guard let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday) else {
            return "Unable to load today's calendar."
        }

        let predicate = store.predicateForEvents(withStart: startOfToday, end: endOfToday, calendars: nil)
        let events = store.events(matching: predicate)
        let formatter = DateFormatter()
        formatter.timeStyle = .short

        var sections: [String] = []

        if events.isEmpty {
            sections.append("Nothing on your calendar for today.")
        } else {
            let eventLines = events.prefix(8).map { event in
                let time = formatter.string(from: event.startDate)
                return "• \(time) — \(event.title ?? "Untitled")"
            }
            sections.append(eventLines.joined(separator: "\n"))
        }

        let remindersGranted: Bool
        if #available(macOS 14.0, *) {
            remindersGranted = (try? await store.requestFullAccessToReminders()) ?? false
        } else {
            remindersGranted = await withCheckedContinuation { continuation in
                store.requestAccess(to: .reminder) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        }

        if remindersGranted {
            let reminderLines = await fetchIncompleteReminders(store: store)
            if !reminderLines.isEmpty {
                sections.append("Reminders:\n\(reminderLines.joined(separator: "\n"))")
            }
        }

        return sections.joined(separator: "\n\n")
    }

    private func fetchIncompleteReminders(store: EKEventStore) async -> [String] {
        await withCheckedContinuation { continuation in
            let calendars = store.calendars(for: .reminder)
            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
            store.fetchReminders(matching: predicate) { reminders in
                let lines = (reminders ?? []).prefix(5).map { reminder in
                    "• \(reminder.title ?? "Untitled")"
                }
                continuation.resume(returning: Array(lines))
            }
        }
    }

    private func buildSuggestions(conversations: [Conversation], profile: UserProfile) -> [String] {
        var items: [String] = []

        let openThreads = conversations.filter { conversation in
            conversation.source == .desktop &&
            conversation.messages.count > 1 &&
            Calendar.current.isDateInToday(conversation.updatedAt)
        }
        if !openThreads.isEmpty {
            let titles = openThreads.prefix(3).map(\.title).joined(separator: ", ")
            items.append("Continue open threads from today: \(titles)")
        }

        for fact in profile.facts.prefix(3) {
            items.append("Based on your profile: \(fact.text)")
        }

        if items.isEmpty {
            items.append("Review your calendar and start a research thread for anything you need to dig into.")
        }

        return items
    }

    private static func snippet(from text: String, maxLength: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxLength { return trimmed }
        return String(trimmed.prefix(maxLength)) + "…"
    }
}
