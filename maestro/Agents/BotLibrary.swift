import Combine
import Foundation

@MainActor
final class BotLibrary: ObservableObject {
  static let shared = BotLibrary()
  nonisolated static let directory = FileManager.default.urls(
    for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Maestro/bots", isDirectory: true)

  // Kept independent of PiRPC: only the legacy migration reads pi's folder.
  private static var legacyCatalogURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Maestro/pi/agents.json")
  }

  private static var defaultBot: BotDefinition {
    BotDefinition(
      id: UUID(uuidString: "C8C21149-726E-4DCB-B219-6885A3D86EB1")!,
      name: "Projects Manager",
      systemPrompt:
        "Help the user plan and coordinate projects. Use Notion when connected. Explain blockers honestly. Specialist delegation is not connected in this first runtime step."
    )
  }

  @Published private(set) var bots: [BotDefinition] = []
  @Published private(set) var loadError: String?

  private init() {
    do {
      try FileManager.default.createDirectory(
        at: Self.directory, withIntermediateDirectories: true)
      var loaded = try loadAll()
      if loaded.isEmpty { loaded = try migrateLegacyCatalog() }
      if loaded.isEmpty {
        try save(Self.defaultBot)
        loaded = [Self.defaultBot]
      }
      bots = loaded
    } catch {
      loadError = "Could not load bots: \(error.localizedDescription)"
    }
  }

  func bot(id: UUID) -> BotDefinition? { bots.first { $0.id == id } }

  func importBot(_ bot: BotDefinition) throws -> UUID {
    if let loadError { throw PiError.message(loadError) }
    if let existing = bots.first(where: {
      $0.name == bot.name && $0.systemPrompt == bot.systemPrompt && $0.execution == bot.execution
        && $0.skills == bot.skills
    }) {
      return existing.id
    }
    var imported = bot
    if self.bot(id: imported.id) != nil { imported.id = UUID() }
    try save(imported)
    bots.append(imported)
    return imported.id
  }

  private func loadAll() throws -> [BotDefinition] {
    let items = try FileManager.default.contentsOfDirectory(
      at: Self.directory, includingPropertiesForKeys: nil)
    var result: [BotDefinition] = []
    for item in items {
      let file = item.appendingPathComponent("definition.json")
      guard FileManager.default.fileExists(atPath: file.path) else { continue }
      result.append(try JSONDecoder().decode(BotDefinition.self, from: Data(contentsOf: file)))
    }
    return result.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  private func migrateLegacyCatalog() throws -> [BotDefinition] {
    let legacy = Self.legacyCatalogURL
    guard FileManager.default.fileExists(atPath: legacy.path) else { return [] }
    let old = try JSONDecoder().decode([BotDefinition].self, from: Data(contentsOf: legacy))
    for bot in old { try save(bot) }
    return old.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  private func save(_ bot: BotDefinition) throws {
    let dir = Self.directory.appendingPathComponent(bot.id.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try JSONEncoder().encode(bot).write(
      to: dir.appendingPathComponent("definition.json"), options: .atomic)
  }
}
