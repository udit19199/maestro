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
    @Published private(set) var lastRefreshedAt: Date?
    @Published private(set) var isRefreshing = false

    private var refreshTimer: Timer?
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

    func refresh(conversationStore: ConversationStore = .shared) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        yesterdayRecap = buildYesterdayRecap(conversations: conversationStore.conversations)
        todayCalendarSummary = await fetchTodayCalendarSummary()
        suggestions = buildSuggestions(
            conversations: conversationStore.conversations,
            profile: ProfileStore.shared.profile
        )
        lastRefreshedAt = Date()
    }

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
