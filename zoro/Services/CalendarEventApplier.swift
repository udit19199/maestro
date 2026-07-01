//
//  CalendarEventApplier.swift
//  zoro
//

import Foundation
import EventKit

enum CalendarEventApplier {
    static func apply(proposals: [PlannerEventProposal]) async -> String {
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
            return "Error: Calendar access was denied. Enable access in System Settings."
        }

        let formatter = ISO8601DateFormatter()
        var created: [String] = []
        var failures: [String] = []

        for proposal in proposals {
            guard let start = formatter.date(from: proposal.startDate),
                  let end = formatter.date(from: proposal.endDate) else {
                failures.append("\(proposal.title): invalid date format")
                continue
            }

            let event = EKEvent(eventStore: store)
            event.title = proposal.title
            event.startDate = start
            event.endDate = end
            event.location = proposal.location
            event.notes = proposal.notes
            event.calendar = store.defaultCalendarForNewEvents

            do {
                try store.save(event, span: .thisEvent)
                created.append(proposal.title)
            } catch {
                failures.append("\(proposal.title): \(error.localizedDescription)")
            }
        }

        var lines: [String] = []
        if !created.isEmpty {
            lines.append("Created \(created.count) event\(created.count == 1 ? "" : "s"): \(created.joined(separator: ", ")).")
        }
        if !failures.isEmpty {
            lines.append("Failed: \(failures.joined(separator: "; ")).")
        }
        return lines.isEmpty ? "No events were created." : lines.joined(separator: " ")
    }
}
