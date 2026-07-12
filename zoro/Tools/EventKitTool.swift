//
//  EventKitTool.swift
//  zoro
//
//  Created by Antigravity on 19/06/26.
//

import Foundation
import FoundationModels
import EventKit

@MainActor
struct EventKitTool: Tool {
    let name = "manage_calendar_and_reminders"
    let description = "List calendar events and reminders. create_event stages a proposal for user confirmation (does not write until confirmed). Other mutations follow policy."
    let executionContext: AgentExecutionContext

    @Generable
    struct Arguments {
        @Guide(description: "The action to perform: 'create_event', 'list_events', 'delete_event', 'create_reminder', 'list_reminders', 'complete_reminder'")
        var action: String
        
        @Guide(description: "The title of the event or reminder")
        var title: String?
        
        @Guide(description: "Start date/time for event (ISO8601 format, e.g., '2026-06-25T15:00:00Z')")
        var startDate: String?
        
        @Guide(description: "End date/time for event (ISO8601 format, e.g., '2026-06-25T16:00:00Z')")
        var endDate: String?
        
        @Guide(description: "Optional location for calendar events")
        var location: String?
        
        @Guide(description: "Optional notes or details for event/reminder")
        var notes: String?
        
        @Guide(description: "Due date/time for a reminder (ISO8601 format, e.g., '2026-06-25T17:00:00Z')")
        var dueDate: String?
        
        @Guide(description: "The ID of the event or reminder to delete or complete")
        var id: String?
    }

    func call(arguments: Arguments) async throws -> String {
        if let permissionError = SecurityPolicy.toolPermissionError(for: name, context: executionContext) {
            return permissionError
        }

        guard SecurityPolicy.isCalendarActionPermitted(arguments.action, context: executionContext) else {
            return "Error: Calendar action '\(arguments.action)' is not permitted in \(SecurityPolicy.contextDescription(executionContext))."
        }

        let eventStore = EKEventStore()
        
        // Request permissions
        let calendarGranted: Bool
        if #available(macOS 14.0, *) {
            calendarGranted = try await eventStore.requestFullAccessToEvents()
        } else {
            calendarGranted = try await withCheckedThrowingContinuation { continuation in
                eventStore.requestAccess(to: .event) { granted, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
        }
        
        let remindersGranted: Bool
        if #available(macOS 14.0, *) {
            remindersGranted = try await eventStore.requestFullAccessToReminders()
        } else {
            remindersGranted = try await withCheckedThrowingContinuation { continuation in
                eventStore.requestAccess(to: .reminder) { granted, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
        }
        
        guard calendarGranted && remindersGranted else {
            return "Error: Calendar or Reminders access was denied by the user. Please enable access in System Settings > Privacy & Security."
        }
        
        let dateFormatter = ISO8601DateFormatter()
        
        switch arguments.action {
        case "create_event":
            // Human-in-the-loop: stage only — user confirms in UI before EventKit write.
            guard let title = arguments.title,
                  let startStr = arguments.startDate,
                  let endStr = arguments.endDate,
                  dateFormatter.date(from: startStr) != nil,
                  dateFormatter.date(from: endStr) != nil else {
                return "Error: Missing required fields ('title', 'startDate', 'endDate') for 'create_event'."
            }

            let proposal = PlannerEventProposal(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                startDate: startStr,
                endDate: endStr,
                location: arguments.location,
                notes: arguments.notes
            )
            var existing = WorkspaceManager.shared.pendingCalendarProposals
            existing.append(proposal)
            WorkspaceManager.shared.setPendingCalendarProposals(existing)
            return """
            Calendar event staged — NOT created. Waiting for user confirmation in Zoro.

            pending_event_id: \(proposal.id.uuidString)
            title: \(proposal.title)
            start: \(startStr)
            end: \(endStr)

            Tell the user to confirm the event in the app before it is added to Calendar.
            """
            
        case "list_events":
            // Fetch events in a range: default from 7 days ago to 30 days ahead
            let start = arguments.startDate.flatMap { dateFormatter.date(from: $0) } ?? Date().addingTimeInterval(-86400 * 7)
            let end = arguments.endDate.flatMap { dateFormatter.date(from: $0) } ?? Date().addingTimeInterval(86400 * 30)
            
            let calendars = eventStore.calendars(for: .event)
            let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: calendars)
            let events = eventStore.events(matching: predicate)
            
            if events.isEmpty {
                return "No events found between \(start) and \(end)."
            }
            
            var lines = ["Calendar Events found:"]
            let outputFormatter = DateFormatter()
            outputFormatter.dateFormat = "yyyy-MM-dd HH:mm"
            for event in events {
                let id = event.eventIdentifier ?? ""
                let title = event.title ?? "Untitled"
                let loc = event.location.map { " @ \($0)" } ?? ""
                let timeStr = "\(outputFormatter.string(from: event.startDate)) to \(outputFormatter.string(from: event.endDate))"
                lines.append("- [\(id)] \(title)\(loc) (\(timeStr))")
            }
            return lines.joined(separator: "\n")
            
        case "delete_event":
            // Destructive: require explicit user confirmation in UI.
            guard let id = arguments.id else {
                return "Error: Missing event 'id' to delete."
            }
            guard let event = eventStore.event(withIdentifier: id) else {
                return "Error: Event with ID \(id) not found."
            }
            let pending = PendingCalendarDelete(
                eventIdentifier: id,
                title: event.title ?? "Untitled",
                conversationID: WorkspaceManager.shared.activeConversationID
            )
            WorkspaceManager.shared.setPendingCalendarDelete(pending)
            return """
            Calendar delete staged — NOT deleted. Waiting for user confirmation in Zoro.

            pending_delete_id: \(pending.id.uuidString)
            event: \(pending.title)
            id: \(id)

            Tell the user to confirm deletion in the app.
            """
            
        case "create_reminder":
            // Human-in-the-loop: stage only — user confirms in UI before Reminders write.
            guard let title = arguments.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
                return "Error: Missing required 'title' field for 'create_reminder'."
            }
            if let dueStr = arguments.dueDate, dateFormatter.date(from: dueStr) == nil {
                return "Error: Invalid dueDate format (use ISO8601)."
            }
            let pending = PendingReminderProposal(
                title: title,
                dueDate: arguments.dueDate,
                notes: arguments.notes,
                conversationID: WorkspaceManager.shared.activeConversationID
            )
            WorkspaceManager.shared.setPendingReminder(pending)
            return """
            Reminder staged — NOT created. Waiting for user confirmation in Zoro.

            pending_reminder_id: \(pending.id.uuidString)
            title: \(title)
            due: \(arguments.dueDate ?? "(none)")

            Tell the user to confirm the reminder in the app before it is saved.
            """
            
        case "list_reminders":
            let calendars = eventStore.calendars(for: .reminder)
            let predicate = eventStore.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
            
            return try await withCheckedThrowingContinuation { continuation in
                eventStore.fetchReminders(matching: predicate) { reminders in
                    let reminderList = reminders ?? []
                    if reminderList.isEmpty {
                        continuation.resume(returning: "No incomplete reminders found.")
                        return
                    }
                    var lines = ["Incomplete Reminders found:"]
                    let outputFormatter = DateFormatter()
                    outputFormatter.dateFormat = "yyyy-MM-dd HH:mm"
                    for r in reminderList {
                        let id = r.calendarItemIdentifier
                        let title = r.title ?? "Untitled"
                        let dueText = r.dueDateComponents?.date.map { " (Due: \(outputFormatter.string(from: $0)))" } ?? ""
                        lines.append("- [\(id)] \(title)\(dueText)")
                    }
                    continuation.resume(returning: lines.joined(separator: "\n"))
                }
            }
            
        case "complete_reminder":
            guard let id = arguments.id else {
                return "Error: Missing reminder 'id' to complete."
            }
            let item = eventStore.calendarItem(withIdentifier: id)
            guard let reminder = item as? EKReminder else {
                return "Error: Reminder with ID \(id) not found."
            }
            let pending = PendingReminderComplete(
                reminderIdentifier: id,
                title: reminder.title ?? "Untitled",
                conversationID: WorkspaceManager.shared.activeConversationID
            )
            WorkspaceManager.shared.setPendingReminderComplete(pending)
            return """
            Reminder complete staged — NOT marked done. Waiting for user confirmation in Zoro.

            pending_complete_id: \(pending.id.uuidString)
            reminder: \(pending.title)

            Tell the user to confirm in the app.
            """
            
        default:
            return "Error: Invalid action '\(arguments.action)'."
        }
    }
}
