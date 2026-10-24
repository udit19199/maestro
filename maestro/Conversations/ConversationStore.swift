//
//  ConversationStore.swift
//  maestro
//
//  Created by Udit Agarwal on 01/07/26.
//

import Combine
import Foundation

@MainActor
final class ConversationStore: ObservableObject {
  static let shared = ConversationStore()

  @Published private(set) var conversations: [Conversation] = []
  @Published var selectedConversationID: UUID?

  private var saveTask: Task<Void, Never>?
  private let saveDebounceNanoseconds: UInt64 = 500_000_000

  private var storageDirectory: URL {
    let appSupport = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first
    let base =
      appSupport?.appendingPathComponent("Maestro", isDirectory: true)
      ?? FileManager.default.temporaryDirectory.appendingPathComponent("Maestro", isDirectory: true)
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
      let data = try migrateBots(in: Data(contentsOf: storageURL))
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let decoded = try decoder.decode([Conversation].self, from: data)
      conversations = decoded.sorted { $0.updatedAt > $1.updatedAt }
      if data != (try Data(contentsOf: storageURL)) { persistNow() }
    } catch {
      print("ConversationStore: failed to load conversations: \(error.localizedDescription)")
    }
  }

  private func migrateBots(in data: Data) throws -> Data {
    guard var records = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      throw PiError.message("The saved conversation file is not a list of chats.")
    }
    for index in records.indices {
      if records[index]["botID"] == nil {
        if records[index]["agentID"] != nil {
          // Earlier shapes already stored the bot reference; only the key is old.
          records[index]["botID"] = records[index]["agentID"]
        } else {
          let bot: BotDefinition
          if let saved = records[index]["agent"] ?? records[index]["customAgent"] {
            bot = try JSONDecoder().decode(
              BotDefinition.self, from: JSONSerialization.data(withJSONObject: saved))
          } else {
            let oldType = records[index]["agentType"] as? String ?? "default"
            let name = oldType == "default" ? "General" : oldType.capitalized
            bot = BotDefinition(
              name: name,
              systemPrompt:
                "You are the user's \(name) assistant. Use only the tools available in this session.")
          }
          records[index]["botID"] = try BotLibrary.shared.importBot(bot).uuidString
        }
      }
      if records[index]["allowsMCP"] == nil {
        records[index]["allowsMCP"] = records[index]["source"] as? String != "imessage"
      }
      for key in ["agent", "customAgent", "agentType", "source", "agentID"] {
        records[index].removeValue(forKey: key)
      }
    }
    return try JSONSerialization.data(withJSONObject: records)
  }

  func selectBot(_ botID: UUID, for conversationID: UUID) {
    guard !PiSessions.shared.isRunning(conversationID: conversationID),
      BotLibrary.shared.bot(id: botID) != nil,
      let index = conversations.firstIndex(where: { $0.id == conversationID }),
      conversations[index].botID != botID
    else { return }
    PiSessions.shared.stopConversation(conversationID)
    conversations[index].botID = botID
    conversations[index].updatedAt = Date()
    scheduleSave()
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
  func createConversation(bot: BotDefinition) -> Conversation {
    let conversation = Conversation(title: "New Chat", botID: bot.id)
    conversations.insert(conversation, at: 0)
    selectedConversationID = conversation.id
    scheduleSave()
    return conversation
  }

  func updateMessage(
    conversationID: UUID, messageID: UUID, content: String,
    status: MessageStatus = .streaming, failure: String? = nil
  ) {
    guard let index = conversations.firstIndex(where: { $0.id == conversationID }),
      let messageIndex = conversations[index].messages.firstIndex(where: { $0.id == messageID })
    else { return }
    var updated = conversations
    updated[index].messages[messageIndex].content = content
    updated[index].messages[messageIndex].status = status
    updated[index].messages[messageIndex].failure = failure
    updated[index].updatedAt = Date()
    conversations = updated
    scheduleSave()
  }

  func selectConversation(_ id: UUID?) {
    selectedConversationID = id
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

  func deleteConversation(_ id: UUID) {
    PiSessions.shared.stopConversation(id)
    conversations.removeAll { $0.id == id }
    if selectedConversationID == id {
      selectedConversationID = nil
    }
    persistNow()
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
