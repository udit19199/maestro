//
//  CalendarConfirmations.swift
//  zoro
//
//  User-confirmed EventKit writes (create/delete/complete).
//

import Foundation
import EventKit

struct PendingReminderProposal: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let dueDate: String?
    let notes: String?
    let conversationID: UUID?

    init(
        id: UUID = UUID(),
        title: String,
        dueDate: String? = nil,
        notes: String? = nil,
        conversationID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.dueDate = dueDate
        self.notes = notes
        self.conversationID = conversationID
    }
}

struct PendingCalendarDelete: Identifiable, Equatable, Sendable {
    let id: UUID
    let eventIdentifier: String
    let title: String
    let conversationID: UUID?

    init(
        id: UUID = UUID(),
        eventIdentifier: String,
        title: String,
        conversationID: UUID? = nil
    ) {
        self.id = id
        self.eventIdentifier = eventIdentifier
        self.title = title
        self.conversationID = conversationID
    }
}

struct PendingReminderComplete: Identifiable, Equatable, Sendable {
    let id: UUID
    let reminderIdentifier: String
    let title: String
    let conversationID: UUID?

    init(
        id: UUID = UUID(),
        reminderIdentifier: String,
        title: String,
        conversationID: UUID? = nil
    ) {
        self.id = id
        self.reminderIdentifier = reminderIdentifier
        self.title = title
        self.conversationID = conversationID
    }
}

enum CalendarConfirmations {
    static func requestEventAccess(store: EKEventStore) async -> Bool {
        // Deployment target is macOS 27+; always use the non-deprecated EventKit APIs.
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    static func requestReminderAccess(store: EKEventStore) async -> Bool {
        (try? await store.requestFullAccessToReminders()) ?? false
    }

    static func createReminder(_ pending: PendingReminderProposal) async -> String {
        let store = EKEventStore()
        guard await requestReminderAccess(store: store) else {
            return "Error: Reminders access was denied. Enable access in System Settings."
        }
        guard let calendar = store.defaultCalendarForNewReminders() else {
            return "Error: No default calendar found for reminders."
        }

        let reminder = EKReminder(eventStore: store)
        reminder.title = pending.title
        reminder.notes = pending.notes
        reminder.calendar = calendar
        if let dueStr = pending.dueDate, let due = ISO8601DateFormatter().date(from: dueStr) {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: due
            )
        }

        do {
            try store.save(reminder, commit: true)
            return "Created reminder: '\(pending.title)'."
        } catch {
            return "Failed to create reminder: \(error.localizedDescription)"
        }
    }

    static func deleteEvent(_ pending: PendingCalendarDelete) async -> String {
        let store = EKEventStore()
        guard await requestEventAccess(store: store) else {
            return "Error: Calendar access was denied."
        }
        guard let event = store.event(withIdentifier: pending.eventIdentifier) else {
            return "Error: Event no longer exists."
        }
        do {
            try store.remove(event, span: .thisEvent)
            return "Deleted calendar event: '\(pending.title)'."
        } catch {
            return "Failed to delete event: \(error.localizedDescription)"
        }
    }

    static func completeReminder(_ pending: PendingReminderComplete) async -> String {
        let store = EKEventStore()
        guard await requestReminderAccess(store: store) else {
            return "Error: Reminders access was denied."
        }
        guard let item = store.calendarItem(withIdentifier: pending.reminderIdentifier) as? EKReminder else {
            return "Error: Reminder no longer exists."
        }
        item.isCompleted = true
        do {
            try store.save(item, commit: true)
            return "Completed reminder: '\(pending.title)'."
        } catch {
            return "Failed to complete reminder: \(error.localizedDescription)"
        }
    }
}
