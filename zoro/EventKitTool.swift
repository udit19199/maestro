//
//  EventKitTool.swift
//  zoro
//
//  Created by Antigravity on 19/06/26.
//

import Foundation
import FoundationModels
import EventKit

struct EventKitTool: Tool {
    let name = "manage_calendar_and_reminders"
    let description = "Create, read, list, and complete native macOS calendar events and reminders."

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
            guard let title = arguments.title,
                  let startStr = arguments.startDate,
                  let endStr = arguments.endDate,
                  let start = dateFormatter.date(from: startStr),
                  let end = dateFormatter.date(from: endStr) else {
                return "Error: Missing required fields ('title', 'startDate', 'endDate') for 'create_event'."
            }
            
            let event = EKEvent(eventStore: eventStore)
            event.title = title
            event.startDate = start
            event.endDate = end
            event.location = arguments.location
            event.notes = arguments.notes
            event.calendar = eventStore.defaultCalendarForNewEvents
            
            try eventStore.save(event, span: .thisEvent)
            return "Successfully created calendar event: '\(title)' (ID: \(event.eventIdentifier ?? ""))"
            
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
            guard let id = arguments.id else {
                return "Error: Missing event 'id' to delete."
            }
            guard let event = eventStore.event(withIdentifier: id) else {
                return "Error: Event with ID \(id) not found."
            }
            try eventStore.remove(event, span: .thisEvent)
            return "Successfully deleted calendar event."
            
        case "create_reminder":
            guard let title = arguments.title else {
                return "Error: Missing required 'title' field for 'create_reminder'."
            }
            
            let reminder = EKReminder(eventStore: eventStore)
            reminder.title = title
            reminder.notes = arguments.notes
            
            guard let defaultCal = eventStore.defaultCalendarForNewReminders() else {
                return "Error: No default calendar found for reminders."
            }
            reminder.calendar = defaultCal
            
            if let dueStr = arguments.dueDate, let dueDate = dateFormatter.date(from: dueStr) {
                let calendar = Calendar.current
                reminder.dueDateComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: dueDate)
            }
            
            try eventStore.save(reminder, commit: true)
            return "Successfully created reminder: '\(title)' (ID: \(reminder.calendarItemIdentifier))"
            
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
            
            reminder.isCompleted = true
            try eventStore.save(reminder, commit: true)
            return "Successfully completed reminder: '\(reminder.title ?? "")'"
            
        default:
            return "Error: Invalid action '\(arguments.action)'."
        }
    }
}
