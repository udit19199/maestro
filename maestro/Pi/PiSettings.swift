import AppKit
import Combine
import Foundation

@MainActor
final class PiSettings: ObservableObject {
  static let shared = PiSettings()
  struct ModelChoice: Identifiable {
    let id: String
    let name: String
  }
  struct ProviderChoice: Identifiable, Decodable {
    let id: String
    let name: String
    let connected: Bool
    let apiKey: Bool
    let oauth: Bool
  }
  private struct ProviderList: Decodable { let providers: [ProviderChoice] }
  private struct AuthNotice: Decodable {
    let authEvent: AuthEvent
    struct AuthEvent: Decodable {
      let url: String?
      let verificationUri: String?
      let instructions: String?
      let message: String?
      let userCode: String?
    }
  }
  enum LoginMethod: String {
    case apiKey = "api_key"
    case oauth
  }
  struct MCPServer: Identifiable {
    let id: String
    let name: String
    let url: String
  }
  static let supportedMCPServers = [
    MCPServer(id: "notion", name: "Notion", url: "https://mcp.notion.com/mcp")
  ]
  @Published var providers: [ProviderChoice] = []
  struct InputRequest: Identifiable {
    enum Kind {
      case secret, text
      case select([String])
    }
    let id: String
    let title: String
    let kind: Kind
  }
  @Published var inputRequest: InputRequest?
  @Published var models: [ModelChoice] = []
  @Published var status = "Choose an inference model."
  enum Operation {
    case idle
    case request(PiCommand)
    case mcp(String)
  }
  @Published private(set) var operation: Operation = .idle
  var busy: Bool {
    if case .idle = operation { return false }
    return true
  }
  private var worker: PiRPC?
  private var loginFailed = false
  private var mcpProcess: Process?
  private var mcpTask: Task<Void, Never>?

  func connect(provider: String, method: LoginMethod) {
    guard !busy, providers.contains(where: { $0.id == provider })
    else { return }
    loginFailed = false
    startRequest(
      .prompt(id: "login", message: "/maestro-connect " + provider + " " + method.rawValue),
      status: "Follow the provider sign-in steps.")
  }

  func submitInput(_ value: String) {
    guard let id = inputRequest?.id else { return }
    inputRequest = nil
    do { try worker?.send(.input(id: id, value: value)) } catch {
      failed("Could not send the login response to pi.")
    }
  }
  func cancel() {
    finish()
    mcpTask?.cancel()
    mcpTask = nil
    if let process = mcpProcess, process.isRunning { process.terminate() }
    mcpProcess = nil
    status = "Connection setup cancelled."
  }
  func refreshProviders() {
    startRequest(
      .prompt(id: "providers", message: "/maestro-providers"),
      status: "Loading providers...")
  }

  private func refreshModels() {
    startRequest(.availableModels, status: "Loading models...")
  }

  private func startRequest(_ command: PiCommand, status: String) {
    guard !busy else { return }
    operation = .request(command)
    self.status = status
    do {
      let worker = try PiRPC()
      self.worker = worker
      worker.onEvent = { [weak self, weak worker] event in
        guard let self, self.worker === worker else { return }
        self.receive(event)
      }
      worker.onFailure = { [weak self, weak worker] message in
        guard let self, self.worker === worker else { return }
        self.failed(message)
      }
      worker.onExit = { [weak self, weak worker] in
        guard let self, self.worker === worker else { return }
        self.failed("Pi stopped during setup.")
      }
      try worker.start()
      try worker.send(command)
    } catch { failed(error.localizedDescription) }
  }

  private func receive(_ event: PiEvent) {
    if event.type == "extension_ui_request" {
      if ["input", "select"].contains(event.method ?? "") {
        guard let id = event.id else { return }
        let title = event.title ?? "Sign in"
        let kind: InputRequest.Kind
        if event.method == "select" {
          kind = .select(event.options ?? [])
        } else {
          kind = title == "maestro.secret" ? .secret : .text
        }
        inputRequest = InputRequest(
          id: id, title: title == "maestro.secret" ? "API key" : title, kind: kind)
      } else if event.method == "notify", let message = event.message?.text {
        let data = Data(message.utf8)
        if let list = try? JSONDecoder().decode(ProviderList.self, from: data) {
          providers = list.providers
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } else if let notice = try? JSONDecoder().decode(AuthNotice.self, from: data) {
          let auth = notice.authEvent
          if let url = auth.url ?? auth.verificationUri,
            let target = URL(string: url), target.scheme == "https"
          {
            NSWorkspace.shared.open(target)
          }
          status = auth.instructions ?? auth.message ?? "Complete sign-in in your browser."
          if let code = auth.userCode { status += " Code: " + code }
        } else {
          if event.notifyType == "error" { loginFailed = true }
          status = message
        }
      }
      return
    }
    guard event.type == "response" else { return }
    if event.success == false {
      failed(event.error ?? "pi rejected the setup request.")
      return
    }
    if event.id == "providers" {
      finish()
      refreshModels()
    } else if event.id == "login" {
      finish()
      if !loginFailed {
        PiSessions.shared.stopAll()
        refreshProviders()
      }
    } else if event.id == "models", let values = event.data?.models {
      models = values.map { value in
        ModelChoice(
          id: value.provider + "/" + value.id,
          name: (value.name ?? value.id) + " · " + value.provider)
      }.sorted { $0.name < $1.name }
      status =
        models.isEmpty
        ? "No connected models. Check your inference connection." : "Choose a model below."
      finish()
    }
  }
  private func finish() {
    worker?.onExit = nil
    worker?.stop()
    worker = nil
    inputRequest = nil
    operation = .idle
  }
  private func failed(_ message: String) {
    status = message
    finish()
  }

  func connectMCP(_ server: MCPServer) {
    guard !busy else { return }
    operation = .mcp(server.id)
    status = "Authorize \(server.name) in your browser."
    mcpTask = Task {
      guard !Task.isCancelled else { return }
      do {
        guard
          let added = try await runMCP([
            "add", server.id, "--url", server.url, "--exposure", "direct",
          ])
        else { return }
        guard added == 0 else { throw PiError.message("Pi could not configure \(server.name).") }
        guard let login = try await runMCP(["login", server.id, "--timeout", "300"]),
          !Task.isCancelled
        else { return }
        status =
          login == 0 ? "\(server.name) connected." : "\(server.name) sign-in failed or timed out."
        if login == 0 { PiSessions.shared.stopAll() }
      } catch {
        guard !Task.isCancelled else { return }
        status = error.localizedDescription
      }
      guard !Task.isCancelled else { return }
      mcpTask = nil
      operation = .idle
    }
  }

  private func runMCP(_ arguments: [String]) async throws -> Int32? {
    let process = Process()
    mcpProcess = process
    try PiRPC.configure(process)
    process.arguments = ["mcp"] + arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    await Task.detached { process.waitUntilExit() }.value
    guard mcpProcess === process else { return nil }
    mcpProcess = nil
    return process.terminationStatus
  }
}
