import Foundation

@MainActor
final class PiRPC {
  static let directory = FileManager.default.urls(
    for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Zoro/pi", isDirectory: true)
  static let configDirectory = directory.appendingPathComponent("agent", isDirectory: true)
  static var executable: String {
    let bundled = directory.appendingPathComponent("runtime/node_modules/.bin/pi").path
    return FileManager.default.isExecutableFile(atPath: bundled) ? bundled : "/opt/homebrew/bin/pi"
  }

  static func configure(_ process: Process) throws {
    try FileManager.default.createDirectory(
      at: configDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    process.executableURL = URL(fileURLWithPath: executable)
    process.environment = environment
    process.currentDirectoryURL = configDirectory
  }

  let process = Process()
  private let input = Pipe()
  private let output = Pipe()
  private var buffer = Data()
  var onEvent: ((PiEvent) -> Void)?
  var onExit: (() -> Void)?
  var onFailure: ((String) -> Void)?

  static var environment: [String: String] {
    var values: [String: String] = [:]
    for name in ["HOME", "USER", "TMPDIR", "LANG"] {
      values[name] = ProcessInfo.processInfo.environment[name]
    }
    values["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    values["PI_CODING_AGENT_DIR"] = Self.configDirectory.path
    return values
  }

  init(
    bot: BotDefinition? = nil, workingDirectory: String? = nil, conversationID: UUID = UUID(),
    allowMCP: Bool = true
  ) throws {
    try Self.configure(process)
    if let workingDirectory {
      // The conversation's repo: pi discovers its skills and runs tools there.
      // A missing folder throws below instead of running somewhere unexpected.
      process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
    }
    var args = ["--mode", "rpc"]
    if let bot {
      let sessions = Self.configDirectory.appendingPathComponent(
        "sessions/\(conversationID.uuidString)", isDirectory: true)
      let modelFlag: String
      switch bot.execution {
      case .pi(let provider, let model):
        if let provider, !provider.isEmpty, !model.contains("/") {
          modelFlag = provider + "/" + model
        } else {
          modelFlag = model
        }
      case .claudeCode:
        throw PiError.message(
          "The bot \"\(bot.name)\" uses Claude Code, which is not connected in this runtime step.")
      case nil:
        modelFlag =
          UserDefaults.standard.string(forKey: "pi_model")
          ?? "cliauthproxy/gpt-6.1-sol"
      }
      args += [
        "--session-dir", sessions.path, "--session-id", conversationID.uuidString,
        "--append-system-prompt", bot.effectiveSystemPrompt,
        "--model", modelFlag,
      ]
      for source in bot.skills {
        if let path = source.resolve(botID: bot.id, workspaceRoot: workingDirectory) {
          args += ["--skill", path]
        }
      }
    } else {
      args += ["--no-session"]
    }
    if bot == nil || !allowMCP { args += ["--no-mcp"] }
    guard let bridge = Bundle.main.url(forResource: "zoro-pi", withExtension: "ts") else {
      throw PiError.message("The pi extension is missing from the app bundle.")
    }
    args += ["-e", bridge.path]
    process.arguments = args
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    output.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
        return
      }
      Task { @MainActor [weak self] in self?.receive(data) }
    }
    process.terminationHandler = { [weak self] _ in
      Task { @MainActor [weak self] in self?.onExit?() }
    }
  }
  func start() throws { try process.run() }
  func send(_ command: PiCommand) throws {
    var data = try JSONEncoder().encode(command)
    data.append(10)
    try input.fileHandleForWriting.write(contentsOf: data)
  }
  func stop() {
    try? send(.abort)
    try? input.fileHandleForWriting.close()
    if process.isRunning { process.terminate() }
  }
  private func receive(_ data: Data) {
    buffer.append(data)
    while let end = buffer.firstIndex(of: 10) {
      let line = buffer.prefix(upTo: end)
      buffer.removeSubrange(...end)
      do {
        onEvent?(try JSONDecoder().decode(PiEvent.self, from: line))
      } catch {
        onFailure?("Pi sent an invalid event: \(error.localizedDescription)")
        return
      }
    }
    if buffer.count > 16_000_000 { stop() }
  }
}

enum PiError: LocalizedError {
  case message(String)
  var errorDescription: String? {
    switch self {
    case .message(let text): return text
    }
  }
}
