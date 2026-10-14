import Foundation

enum MessageRole: String, Codable, Sendable {
  case user, assistant
}

enum MessageStatus: String, Codable, Sendable {
  case streaming, completed, failed, stopped, interrupted
}

struct StoredMessage: Identifiable, Codable, Equatable, Sendable {
  let id: UUID
  let role: MessageRole
  let botID: UUID?
  var content: String
  var status: MessageStatus
  var failure: String?

  init(
    id: UUID = UUID(), role: MessageRole, content: String, botID: UUID? = nil,
    status: MessageStatus = .completed, failure: String? = nil
  ) {
    self.id = id
    self.role = role
    self.content = content
    self.botID = botID
    self.status = status
    self.failure = failure
  }

  private enum CodingKeys: String, CodingKey {
    case id, role, content, botID, status, failure
    // Pre-bot replies stored the bot reference under this key.
    case agentID
  }
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    role = try values.decode(MessageRole.self, forKey: .role)
    content = try values.decode(String.self, forKey: .content)
    if let bot = try values.decodeIfPresent(UUID.self, forKey: .botID) {
      botID = bot
    } else {
      botID = try values.decodeIfPresent(UUID.self, forKey: .agentID)
    }
    let savedStatus = try values.decodeIfPresent(MessageStatus.self, forKey: .status) ?? .completed
    // A process cannot resume an in-flight request after an app restart.
    status = savedStatus == .streaming ? .interrupted : savedStatus
    failure = try values.decodeIfPresent(String.self, forKey: .failure)
  }

  func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(id, forKey: .id)
    try values.encode(role, forKey: .role)
    try values.encode(content, forKey: .content)
    try values.encodeIfPresent(botID, forKey: .botID)
    try values.encode(status, forKey: .status)
    try values.encodeIfPresent(failure, forKey: .failure)
  }
}
