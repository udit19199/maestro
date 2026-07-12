//
//  ConversationStore.swift
//  zoro
//
//  Created by Udit Agarwal on 01/07/26.
//

import Foundation
import Combine

@MainActor
final class ConversationStore: ObservableObject {
    static let shared = ConversationStore()

    @Published private(set) var conversations: [Conversation] = []
    @Published var selectedConversationID: UUID?

    private var saveTask: Task<Void, Never>?
    private let saveDebounceNanoseconds: UInt64 = 500_000_000

    private var storageDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let base = appSupport?.appendingPathComponent("Zoro", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("Zoro", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private var storageURL: URL {
        storageDirectory.appendingPathComponent("conversations.json")
    }

    private init() {}

    func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode([Conversation].self, from: data)
            conversations = decoded.sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            print("ConversationStore: failed to load conversations: \(error.localizedDescription)")
        }
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: saveDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            self.persistNow()
        }
    }

    func persistNow() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(conversations)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            print("ConversationStore: failed to save conversations: \(error.localizedDescription)")
        }
    }

    func conversation(id: UUID) -> Conversation? {
        conversations.first { $0.id == id }
    }

    @discardableResult
    func createConversation(
        agentType: AgentType,
        source: ConversationSource = .desktop,
        title: String? = nil,
        select: Bool = true,
        remoteRequester: String? = nil
    ) -> Conversation {
        var conversation = Conversation.new(
            agentType: agentType,
            source: source,
            remoteRequester: remoteRequester
        )
        if let title {
            conversation.title = title
        }
        conversations.insert(conversation, at: 0)
        if select {
            selectedConversationID = conversation.id
        }
        scheduleSave()
        return conversation
    }

    func updateTutoringMetadata(
        conversationID: UUID,
        update: (inout TutoringMetadata) -> Void
    ) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        var metadata = conversations[index].tutoringMetadata ?? TutoringMetadata()
        update(&metadata)
        conversations[index].tutoringMetadata = metadata
        conversations[index].updatedAt = Date()
        scheduleSave()
    }

    func recentDesktopConversations(since date: Date) -> [Conversation] {
        conversations.filter { $0.source == .desktop && $0.updatedAt >= date }
    }

    func selectConversation(_ id: UUID?) {
        selectedConversationID = id
    }

    func updateConversation(_ conversation: Conversation) {
        guard let index = conversations.firstIndex(where: { $0.id == conversation.id }) else { return }
        conversations[index] = conversation
        scheduleSave()
    }

    func appendMessage(to conversationID: UUID, message: StoredMessage) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].messages.append(message)
        conversations[index].updatedAt = Date()
        if conversations[index].title == "New Chat", message.role == .user {
            conversations[index].title = Self.titleFromFirstMessage(message.content)
        }
        reorderConversation(at: index)
        scheduleSave()
    }

    func updateLastMessageContent(conversationID: UUID, content: String) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }),
              !conversations[index].messages.isEmpty else { return }
        let lastIndex = conversations[index].messages.count - 1
        conversations[index].messages[lastIndex].content = content
        conversations[index].updatedAt = Date()
        scheduleSave()
    }

    func deleteConversation(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        if selectedConversationID == id {
            selectedConversationID = nil
        }
        scheduleSave()
    }

    private func reorderConversation(at index: Int) {
        let conversation = conversations.remove(at: index)
        conversations.insert(conversation, at: 0)
    }

    private static func titleFromFirstMessage(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 40 {
            return trimmed.isEmpty ? "New Chat" : trimmed
        }
        let prefix = trimmed.prefix(40)
        return "\(prefix)…"
    }
}
