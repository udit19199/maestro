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

    init(
        id: UUID = UUID(),
        title: String,
        agentType: AgentType,
        messages: [StoredMessage] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        tutoringMetadata: TutoringMetadata? = nil,
        source: ConversationSource = .desktop
    ) {
        self.id = id
        self.title = title
        self.agentType = agentType
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.tutoringMetadata = tutoringMetadata
        self.source = source
    }

    static func new(agentType: AgentType, source: ConversationSource = .desktop) -> Conversation {
        let greeting = StoredMessage(role: .assistant, content: agentType.greeting)
        return Conversation(
            title: "New Chat",
            agentType: agentType,
            messages: [greeting],
            source: source
        )
    }
}
