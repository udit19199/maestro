//
//  Conversation.swift
//  zoro
//
//  Created by Udit Agarwal on 01/07/26.
//

import Foundation

enum ConversationSource: String, Codable, Sendable {
    case desktop
    case imessage
}

struct TutoringMetadata: Codable, Equatable, Sendable {
    var curriculumTopic: String?
    var lastLessonSummary: String?
    var currentModule: String?
    var completedModules: [String]?
    var nextExercise: String?
    var understandingChecks: [String]?
}

struct Conversation: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var agentType: AgentType
    var messages: [StoredMessage]
    var createdAt: Date
    var updatedAt: Date
    var tutoringMetadata: TutoringMetadata?
    var source: ConversationSource
    /// Set once for iMessage-sourced threads (chat.db handle). Used for authorization.
    var remoteRequester: String?

    init(
        id: UUID = UUID(),
        title: String,
        agentType: AgentType,
        messages: [StoredMessage] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        tutoringMetadata: TutoringMetadata? = nil,
        source: ConversationSource = .desktop,
        remoteRequester: String? = nil
    ) {
        self.id = id
        self.title = title
        self.agentType = agentType
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.tutoringMetadata = tutoringMetadata
        self.source = source
        self.remoteRequester = remoteRequester
    }

    static func new(
        agentType: AgentType,
        source: ConversationSource = .desktop,
        remoteRequester: String? = nil
    ) -> Conversation {
        let greeting = StoredMessage(role: .assistant, content: agentType.greeting)
        return Conversation(
            title: "New Chat",
            agentType: agentType,
            messages: [greeting],
            source: source,
            remoteRequester: remoteRequester
        )
    }

    /// Derives tool authorization context. iMessage without requester → fail closed.
    func executionContext() -> Result<AgentExecutionContext, ConversationSecurityError> {
        switch source {
        case .desktop:
            return .success(.local)
        case .imessage:
            let requester = remoteRequester?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !requester.isEmpty else {
                return .failure(.missingRemoteRequester)
            }
            return .success(.iMessage(requester: requester))
        }
    }
}

enum ConversationSecurityError: Error, LocalizedError, Equatable {
    case missingRemoteRequester

    var errorDescription: String? {
        switch self {
        case .missingRemoteRequester:
            return "Error: This iMessage conversation is missing a bound requester. Remote tools are disabled. Send a new `zoro:` command to start a fresh session."
        }
    }
}
