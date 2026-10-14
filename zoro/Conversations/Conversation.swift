import Foundation

struct Conversation: Identifiable, Codable, Equatable, Sendable {
  let id: UUID
  var title: String
  var botID: UUID
  var messages: [StoredMessage]
  var createdAt: Date
  var updatedAt: Date
  var allowsMCP: Bool
  // Working folder pi runs in. Nil means no repo: pi stays in its config dir.
  var workingDirectory: String?

  init(
    id: UUID = UUID(), title: String, botID: UUID, messages: [StoredMessage] = [],
    createdAt: Date = Date(), updatedAt: Date = Date(), allowsMCP: Bool = true,
    workingDirectory: String? = nil
  ) {
    self.id = id
    self.title = title
    self.botID = botID
    self.messages = messages
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.allowsMCP = allowsMCP
    self.workingDirectory = workingDirectory
  }

  private enum CodingKeys: String, CodingKey {
    case id, title, botID, messages, createdAt, updatedAt, allowsMCP, workingDirectory
    // Pre-bot chats stored the bot reference under this key.
    case agentID
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    title = try values.decode(String.self, forKey: .title)
    if let bot = try values.decodeIfPresent(UUID.self, forKey: .botID) {
      botID = bot
    } else {
      botID = try values.decode(UUID.self, forKey: .agentID)
    }
    messages = try values.decode([StoredMessage].self, forKey: .messages)
    createdAt = try values.decode(Date.self, forKey: .createdAt)
    updatedAt = try values.decode(Date.self, forKey: .updatedAt)
    allowsMCP = try values.decodeIfPresent(Bool.self, forKey: .allowsMCP) ?? true
    workingDirectory = try values.decodeIfPresent(String.self, forKey: .workingDirectory)
  }

  func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(id, forKey: .id)
    try values.encode(title, forKey: .title)
    try values.encode(botID, forKey: .botID)
    try values.encode(messages, forKey: .messages)
    try values.encode(createdAt, forKey: .createdAt)
    try values.encode(updatedAt, forKey: .updatedAt)
    try values.encode(allowsMCP, forKey: .allowsMCP)
    try values.encodeIfPresent(workingDirectory, forKey: .workingDirectory)
  }
}
