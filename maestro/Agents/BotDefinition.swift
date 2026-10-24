import Foundation

struct BotDefinition: Identifiable, Codable, Equatable, Sendable {
  var id: UUID
  var name: String
  var systemPrompt: String
  var execution: ExecutionChoice?
  var skills: [SkillSource]

  init(
    id: UUID = UUID(), name: String, systemPrompt: String,
    execution: ExecutionChoice? = nil, skills: [SkillSource] = []
  ) {
    self.id = id
    self.name = name
    self.systemPrompt = systemPrompt
    self.execution = execution
    self.skills = skills
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, systemPrompt, execution, skills
  }
  // AgentDefinition-era JSON used these keys.
  private enum LegacyKeys: String, CodingKey { case id, name, instructions, model }

  init(from decoder: Decoder) throws {
    if let values = try? decoder.container(keyedBy: CodingKeys.self),
      values.contains(.systemPrompt)
    {
      id = try values.decode(UUID.self, forKey: .id)
      name = try values.decode(String.self, forKey: .name)
      systemPrompt = try values.decode(String.self, forKey: .systemPrompt)
      execution = try values.decodeIfPresent(ExecutionChoice.self, forKey: .execution)
      skills = try values.decodeIfPresent([SkillSource].self, forKey: .skills) ?? []
    } else {
      let values = try decoder.container(keyedBy: LegacyKeys.self)
      id = try values.decode(UUID.self, forKey: .id)
      name = try values.decode(String.self, forKey: .name)
      systemPrompt = try values.decode(String.self, forKey: .instructions)
      let model = try values.decodeIfPresent(String.self, forKey: .model)
      execution = model.flatMap { $0.isEmpty ? nil : ExecutionChoice.piFromCombined($0) }
      skills = []
    }
  }

  func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(id, forKey: .id)
    try values.encode(name, forKey: .name)
    try values.encode(systemPrompt, forKey: .systemPrompt)
    try values.encodeIfPresent(execution, forKey: .execution)
    try values.encode(skills, forKey: .skills)
  }

  /// Attached skills are used through pi's skill loading, not pasted in.
  /// This line tells the model to load them; pi supplies their instructions.
  var skillInstructionLine: String? {
    let names = skills.map(\.displayName).filter { !$0.isEmpty }
    guard !names.isEmpty else { return nil }
    return
      "Always use these attached skills when they apply: " + names.joined(separator: ", ")
      + ". Load each skill's full instructions before answering."
  }

  var effectiveSystemPrompt: String {
    guard let line = skillInstructionLine else { return systemPrompt }
    return systemPrompt + "\n\n" + line
  }
}

enum ExecutionChoice: Codable, Equatable, Sendable {
  case pi(provider: String?, model: String)
  case claudeCode(model: String)

  /// Old definitions stored one combined "provider/model" string.
  static func piFromCombined(_ combined: String) -> ExecutionChoice {
    guard let slash = combined.firstIndex(of: "/") else {
      return .pi(provider: nil, model: combined)
    }
    let provider = String(combined[..<slash])
    let model = String(combined[combined.index(after: slash)...])
    return .pi(provider: provider.isEmpty ? nil : provider, model: model)
  }
}

enum SkillSource: Codable, Equatable, Sendable {
  case machine(path: String)
  case workspace(relativePath: String)
  case bundled(relativePath: String)

  var displayName: String {
    switch self {
    case .machine(let path):
      return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).lastPathComponent
    case .workspace(let relativePath):
      return URL(fileURLWithPath: relativePath).lastPathComponent
    case .bundled(let relativePath):
      return URL(fileURLWithPath: relativePath).lastPathComponent
    }
  }

  /// Absolute path pi can load with --skill. Nil means there is nothing to
  /// pass: workspace skills need a conversation folder, and this chat has none.
  func resolve(botID: UUID, workspaceRoot: String?) -> String? {
    switch self {
    case .machine(let path):
      return (path as NSString).expandingTildeInPath
    case .workspace(let relativePath):
      guard let workspaceRoot else { return nil }
      return URL(fileURLWithPath: workspaceRoot, isDirectory: true)
        .appendingPathComponent(relativePath).path
    case .bundled(let relativePath):
      return BotLibrary.directory
        .appendingPathComponent(botID.uuidString, isDirectory: true)
        .appendingPathComponent("skills", isDirectory: true)
        .appendingPathComponent(relativePath).path
    }
  }
}
