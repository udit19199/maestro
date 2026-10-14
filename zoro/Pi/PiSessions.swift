import Combine
import Foundation

@MainActor
final class PiSessions: ObservableObject {
  static let shared = PiSessions()

  struct Approval {
    let requestID: String
    let title: String
    let message: String
  }
  enum RunPhase {
    case streaming
    case awaitingApproval(Approval)
    case settling
  }
  struct Run {
    let messageID: UUID
    let botID: UUID
    var text = ""
    var failure: String?
    var phase: RunPhase = .streaming
  }

  @Published private(set) var runs: [UUID: Run] = [:]
  private var processes: [UUID: PiRPC] = [:]

  func approval(for id: UUID) -> Approval? {
    guard case .awaitingApproval(let approval) = runs[id]?.phase else { return nil }
    return approval
  }
  func isRunning(conversationID: UUID) -> Bool { runs[conversationID] != nil }
  func stopAll() { for id in Array(processes.keys) { stopConversation(id) } }
  func stopConversation(_ id: UUID) {
    processes.removeValue(forKey: id)?.stop()
    finish(id, status: .stopped)
  }
  func approve(_ id: UUID, allowed: Bool) {
    guard let approval = approval(for: id) else { return }
    do {
      try processes[id]?.send(.approval(id: approval.requestID, allowed: allowed))
      runs[id]?.phase = .streaming
    } catch { fail(id, error.localizedDescription) }
  }
  func sendMessage(conversationID: UUID, text prompt: String) async {
    let store = ConversationStore.shared
    let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty, !isRunning(conversationID: conversationID),
      let conversation = store.conversation(id: conversationID)
    else { return }
    guard let bot = BotLibrary.shared.bot(id: conversation.botID) else { return }
    let id = conversationID
    store.appendMessage(to: id, message: StoredMessage(role: .user, content: prompt))
    let response = StoredMessage(
      role: .assistant, content: "", botID: bot.id, status: .streaming)
    runs[id] = Run(messageID: response.id, botID: bot.id)
    store.appendMessage(to: id, message: response)
    do {
      let worker: PiRPC
      if let existing = processes[id], existing.process.isRunning {
        worker = existing
      } else {
        worker = try PiRPC(
          bot: bot, workingDirectory: conversation.workingDirectory, conversationID: id,
          allowMCP: conversation.allowsMCP)
        processes[id] = worker
        worker.onEvent = { [weak self, weak worker] event in
          guard let self, self.processes[id] === worker else { return }
          self.receive(event, id: id)
        }
        worker.onFailure = { [weak self, weak worker] message in
          guard let self, self.processes[id] === worker else { return }
          self.fail(id, message)
        }
        worker.onExit = { [weak self, weak worker] in
          guard let self, self.processes[id] === worker else { return }
          self.processes.removeValue(forKey: id)
          self.finish(id, status: .failed, failure: "Pi exited before completing the request.")
        }
        try worker.start()
      }
      try worker.send(.prompt(id: UUID().uuidString, message: prompt))
    } catch { fail(id, error.localizedDescription) }
  }
  private func fail(_ id: UUID, _ message: String) {
    processes.removeValue(forKey: id)?.stop()
    finish(id, status: .failed, failure: message)
  }
  private func finish(_ id: UUID, status: MessageStatus, failure: String? = nil) {
    guard let run = runs.removeValue(forKey: id) else { return }
    ConversationStore.shared.updateMessage(
      conversationID: id, messageID: run.messageID, content: run.text,
      status: status, failure: failure ?? run.failure)
    ConversationStore.shared.persistNow()
  }
  private func update(_ id: UUID) {
    guard let run = runs[id] else { return }
    ConversationStore.shared.updateMessage(
      conversationID: id, messageID: run.messageID, content: run.text)
  }
  private func receive(_ event: PiEvent, id: UUID) {
    guard runs[id] != nil else { return }
    switch event.type {
    case "message_start":
      if case .assistant(let role, _) = event.message, role == "assistant" {
        runs[id]?.text = ""
      }
    case "message_update":
      if event.assistantMessageEvent?.type == "text_delta",
        let delta = event.assistantMessageEvent?.delta
      {
        runs[id]?.text += delta
        update(id)
      }
    case "message_end":
      if case .assistant(_, let error) = event.message, let error {
        runs[id]?.failure = error
      }
    case "agent_settled":
      runs[id]?.phase = .settling
      do { try processes[id]?.send(.lastAssistantText) } catch {
        fail(id, error.localizedDescription)
      }
    case "response":
      if event.success == false {
        fail(id, event.error ?? "Pi rejected this request.")
      } else if event.id == "final", let data = event.data {
        if let text = data.text, !text.isEmpty { runs[id]?.text = text }
        finish(id, status: runs[id]?.failure == nil ? .completed : .failed)
      } else if event.data?.disposition == "handled" {
        runs[id]?.text = "Command handled."
        finish(id, status: .completed)
      }
    case "extension_ui_request":
      guard let requestID = event.id else { return }
      if event.method == "confirm" {
        runs[id]?.phase = .awaitingApproval(
          Approval(
            requestID: requestID, title: event.title ?? "Approve change",
            message: event.message?.text ?? ""))
      } else if ["input", "editor", "select"].contains(event.method ?? "") {
        do { try processes[id]?.send(.cancelInput(id: requestID)) } catch {
          fail(id, error.localizedDescription)
        }
      }
    default: break
    }
  }
}
