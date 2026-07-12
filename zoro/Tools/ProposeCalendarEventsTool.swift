//
//  ProposeCalendarEventsTool.swift
//  zoro
//

import Foundation
import FoundationModels

@MainActor
struct ProposeCalendarEventsTool: Tool {
    let name = "propose_calendar_events"
    let description = "Propose one or more calendar events for user confirmation. Does not create events until the user confirms in chat."
    let executionContext: AgentExecutionContext

    @Generable
    struct ProposedEvent: Codable {
        @Guide(description: "Event title")
        var title: String

        @Guide(description: "Start date/time in ISO8601 format")
        var startDate: String

        @Guide(description: "End date/time in ISO8601 format")
        var endDate: String

        @Guide(description: "Optional location")
        var location: String?

        @Guide(description: "Optional notes")
        var notes: String?
    }

    @Generable
    struct Arguments {
        @Guide(description: "Events to propose for calendar confirmation")
        var events: [ProposedEvent]
    }

    func call(arguments: Arguments) async throws -> String {
        if let permissionError = SecurityPolicy.toolPermissionError(for: name, context: executionContext) {
            return permissionError
        }
        guard !arguments.events.isEmpty else {
            return "Error: no events provided."
        }

        let proposals = arguments.events.compactMap { event -> PlannerEventProposal? in
            let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return PlannerEventProposal(
                title: title,
                startDate: event.startDate,
                endDate: event.endDate,
                location: event.location,
                notes: event.notes
            )
        }

        guard !proposals.isEmpty else {
            return "Error: all proposed events were invalid."
        }

        var existing = WorkspaceManager.shared.pendingCalendarProposals
        existing.append(contentsOf: proposals)
        WorkspaceManager.shared.setPendingCalendarProposals(existing)
        let count = proposals.count
        return "Proposed \(count) calendar event\(count == 1 ? "" : "s") for user confirmation. Waiting for approval before creating."
    }
}

struct PlannerEventProposal: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let startDate: String
    let endDate: String
    let location: String?
    let notes: String?

    init(
        id: UUID = UUID(),
        title: String,
        startDate: String,
        endDate: String,
        location: String? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.location = location
        self.notes = notes
    }
}
