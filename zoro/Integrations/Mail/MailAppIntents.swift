//
//  MailAppIntents.swift
//  zoro
//
//  Phase 1 stub: App Intents schemas for future Siri AI / Spotlight surfacing.
//

import AppIntents
import Foundation

struct MailMessageEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Mail Message")
    static var defaultQuery = MailMessageEntityQuery()

    var id: String
    var subject: String
    var sender: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(subject)", subtitle: "\(sender)")
    }
}

struct MailMessageEntityQuery: EntityQuery {
    func entities(for identifiers: [MailMessageEntity.ID]) async throws -> [MailMessageEntity] {
        []
    }

    func suggestedEntities() async throws -> [MailMessageEntity] {
        []
    }
}

struct SummarizeInboxIntent: AppIntent {
    static var title: LocalizedStringResource = "Summarize Inbox"
    static var description = IntentDescription("Summarize unread mail in Zoro.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let digest = BriefingService.shared.inboxDigest
        let message = digest.isEmpty ? "No unread mail to summarize." : digest
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

struct ZoroMailShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SummarizeInboxIntent(),
            phrases: [
                "Summarize inbox in \(.applicationName)",
                "What's unread in \(.applicationName)",
            ],
            shortTitle: "Summarize Inbox",
            systemImageName: "envelope"
        )
    }
}
