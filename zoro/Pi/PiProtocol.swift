import Foundation

// Commands are encoded here so callers cannot invent wire field names.
enum PiCommand: Encodable {
  case prompt(id: String, message: String)
  case availableModels
  case lastAssistantText
  case abort
  case input(id: String, value: String)
  case approval(id: String, allowed: Bool)
  case cancelInput(id: String)

  private enum CodingKeys: String, CodingKey {
    case type, id, message, value, confirmed, cancelled
  }

  func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .prompt(let id, let message):
      try values.encode("prompt", forKey: .type)
      try values.encode(id, forKey: .id)
      try values.encode(message, forKey: .message)
    case .availableModels:
      try values.encode("get_available_models", forKey: .type)
      try values.encode("models", forKey: .id)
    case .lastAssistantText:
      try values.encode("get_last_assistant_text", forKey: .type)
      try values.encode("final", forKey: .id)
    case .abort:
      try values.encode("abort", forKey: .type)
      try values.encode(UUID().uuidString, forKey: .id)
    case .input(let id, let value):
      try values.encode("extension_ui_response", forKey: .type)
      try values.encode(id, forKey: .id)
      try values.encode(value, forKey: .value)
    case .approval(let id, let allowed):
      try values.encode("extension_ui_response", forKey: .type)
      try values.encode(id, forKey: .id)
      try values.encode(allowed, forKey: .confirmed)
    case .cancelInput(let id):
      try values.encode("extension_ui_response", forKey: .type)
      try values.encode(id, forKey: .id)
      try values.encode(true, forKey: .cancelled)
    }
  }
}

// Pi adds events over time. Unknown event names remain strings and are ignored by consumers.
struct PiEvent: Decodable {
  let type: String
  private(set) var id: String?
  private(set) var success: Bool?
  private(set) var error: String?
  private(set) var method: String?
  private(set) var title: String?
  private(set) var message: PiEventMessage?
  private(set) var options: [String]?
  private(set) var notifyType: String?
  private(set) var assistantMessageEvent: TextDelta?
  private(set) var data: ResponseData?

  private enum CodingKeys: String, CodingKey {
    case type, id, success, error, method, title, message, options, notifyType
    case assistantMessageEvent, data
  }
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    type = try values.decode(String.self, forKey: .type)
    switch type {
    case "message_start", "message_end":
      message = try values.decodeIfPresent(PiEventMessage.self, forKey: .message)
    case "message_update":
      assistantMessageEvent = try values.decodeIfPresent(
        TextDelta.self, forKey: .assistantMessageEvent)
    case "response":
      id = try values.decodeIfPresent(String.self, forKey: .id)
      success = try values.decode(Bool.self, forKey: .success)
      error = try values.decodeIfPresent(String.self, forKey: .error)
      data = try values.decodeIfPresent(ResponseData.self, forKey: .data)
    case "extension_ui_request":
      id = try values.decode(String.self, forKey: .id)
      method = try values.decode(String.self, forKey: .method)
      title = try values.decodeIfPresent(String.self, forKey: .title)
      message = try values.decodeIfPresent(PiEventMessage.self, forKey: .message)
      options = try values.decodeIfPresent([String].self, forKey: .options)
      notifyType = try values.decodeIfPresent(String.self, forKey: .notifyType)
    default: break
    }
  }

  struct TextDelta: Decodable {
    let type: String
    let delta: String?
  }
  struct ResponseData: Decodable {
    let text: String?
    let disposition: String?
    let models: [Model]?
  }
  struct Model: Decodable {
    let provider: String
    let id: String
    let name: String?
  }
}

enum PiEventMessage: Decodable {
  case text(String)
  case assistant(role: String, error: String?)

  private enum CodingKeys: String, CodingKey { case role, errorMessage }
  init(from decoder: Decoder) throws {
    if let text = try? decoder.singleValueContainer().decode(String.self) {
      self = .text(text)
    } else {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      self = .assistant(
        role: try values.decode(String.self, forKey: .role),
        error: try values.decodeIfPresent(String.self, forKey: .errorMessage))
    }
  }
  var text: String? {
    if case .text(let text) = self { return text }
    return nil
  }
}
