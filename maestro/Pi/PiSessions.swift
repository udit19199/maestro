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
    // Bot-to-bot messages that led to this run; caps hand-off chains.
    var hops = 0
  }
  static let maxHops = 4

  // Keyed by conversation; one bot speaks at a time, even in a group.
  @Published private(set) var runs: [UUID: Run] = [:]
  // Conversation -> bot -> process. A group keeps one process per member.
  private var processes: [UUID: [UUID: PiRPC]] = [:]
  // Turns waiting for a busy chat, run in order when its current run ends.
  // Nil text means the line is already posted; nil speakers means route by mentions.
  private struct Turn {
    var text: String?
    var from: UUID?
    var speakers: [UUID]?
    var hops: Int
  }
  private var inbox: [UUID: [Turn]] = [:]

  func approval(for id: UUID) -> Approval? {
    guard case .awaitingApproval(let approval) = runs[id]?.phase else { return nil }
    return approval
  }
  func isRunning(conversationID: UUID) -> Bool { runs[conversationID] != nil }
  func stopAll() { for id in Array(processes.keys) { stopConversation(id) } }
  func stopConversation(_ id: UUID) {
    inbox[id] = nil
    processes.removeValue(forKey: id)?.values.forEach { $0.stop() }
    finish(id, status: .stopped)
  }
  private func worker(_ id: UUID) -> PiRPC? {
    runs[id].flatMap { processes[id]?[$0.botID] }
  }
  func approve(_ id: UUID, allowed: Bool) {
    guard let approval = approval(for: id) else { return }
    do {
      try worker(id)?.send(.approval(id: approval.requestID, allowed: allowed))
      runs[id]?.phase = .streaming
    } catch { fail(id, error.localizedDescription) }
  }
  /// Posts `text` (from the user, or from bot `from`) and runs the speakers one after another.
  /// In a group with no speakers given, @mentioned members answer, else the lead bot.
  func sendMessage(
    conversationID: UUID, text: String?, from sender: UUID? = nil, speakers: [UUID]? = nil,
    hops: Int = 0
  ) async {
    let store = ConversationStore.shared
    let text = text?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text?.isEmpty != true, !isRunning(conversationID: conversationID),
      let conversation = store.conversation(id: conversationID)
    else { return }
    let speakers = speakers ?? Self.mentioned(in: text ?? "", conversation)
    guard let bot = BotLibrary.shared.bot(id: speakers[0]) else { return }
    let id = conversationID
    if let text {
      store.appendMessage(to: id, message: StoredMessage(role: .user, content: text, botID: sender))
    }
    if speakers.count > 1 {
      inbox[id, default: []].insert(
        Turn(text: nil, speakers: Array(speakers.dropFirst()), hops: hops), at: 0)
    }
    let prompt =
      conversation.isGroup
      ? Self.unseen(by: bot.id, in: store.conversation(id: id)!) : text ?? ""
    let response = StoredMessage(
      role: .assistant, content: "", botID: bot.id, status: .streaming)
    runs[id] = Run(messageID: response.id, botID: bot.id, hops: hops)
    store.appendMessage(to: id, message: response)
    do {
      let worker: PiRPC
      if let existing = processes[id]?[bot.id], existing.process.isRunning {
        worker = existing
      } else {
        worker = try PiRPC(
          bot: bot, workingDirectory: conversation.workingDirectory, conversationID: id,
          allowMCP: conversation.allowsMCP, inGroup: conversation.isGroup)
        processes[id, default: [:]][bot.id] = worker
        worker.onEvent = { [weak self, weak worker] event in
          guard let self, self.processes[id]?[bot.id] === worker else { return }
          self.receive(event, id: id)
        }
        worker.onFailure = { [weak self, weak worker] message in
          guard let self, self.processes[id]?[bot.id] === worker else { return }
          self.fail(id, message)
        }
        worker.onExit = { [weak self, weak worker] in
          guard let self, self.processes[id]?[bot.id] === worker else { return }
          self.processes[id]?[bot.id] = nil
          guard self.runs[id]?.botID == bot.id else { return }
          self.finish(id, status: .failed, failure: "Pi exited before completing the request.")
        }
        try worker.start()
      }
      try worker.send(.prompt(id: UUID().uuidString, message: prompt))
    } catch { fail(id, error.localizedDescription) }
  }
  /// Group members @mentioned in `text`, in the order they appear; else the lead bot.
  // ponytail: plain substring match, so "@Al" also matches a bot named "Alex".
  private static func mentioned(in text: String, _ chat: Conversation) -> [UUID] {
    guard chat.isGroup else { return [chat.botID] }
    let found = chat.memberIDs.compactMap { id -> (String.Index, UUID)? in
      guard let name = BotLibrary.shared.bot(id: id)?.name,
        let range = text.range(of: "@" + name, options: .caseInsensitive)
      else { return nil }
      return (range.lowerBound, id)
    }
    return found.isEmpty ? [chat.botID] : found.sorted { $0.0 < $1.0 }.map(\.1)
  }
  /// The group lines a member has not seen: everything after its own last reply.
  private static func unseen(by botID: UUID, in chat: Conversation) -> String {
    let name = { (id: UUID?) in id.flatMap { BotLibrary.shared.bot(id: $0)?.name } ?? "User" }
    let start =
      chat.messages.lastIndex { $0.role == .assistant && $0.botID == botID }.map { $0 + 1 } ?? 0
    let lines = chat.messages[start...].filter { !$0.content.isEmpty }.map {
      "\(name($0.botID)): \($0.content)"
    }
    let members = chat.memberIDs.map(name).joined(separator: ", ")
    return "Group chat with \(members). New messages since your last reply:\n\n"
      + lines.joined(separator: "\n\n")
  }
  private func fail(_ id: UUID, _ message: String) {
    if let bot = runs[id]?.botID { processes[id]?.removeValue(forKey: bot)?.stop() }
    finish(id, status: .failed, failure: message)
  }
  private func finish(_ id: UUID, status: MessageStatus, failure: String? = nil) {
    guard let run = runs.removeValue(forKey: id) else { return }
    ConversationStore.shared.updateMessage(
      conversationID: id, messageID: run.messageID, content: run.text,
      status: status, failure: failure ?? run.failure)
    ConversationStore.shared.persistNow()
    if var queued = inbox[id], !queued.isEmpty {
      let next = queued.removeFirst()
      inbox[id] = queued.isEmpty ? nil : queued
      start(next, in: id)
    }
  }
  private func start(_ turn: Turn, in id: UUID) {
    Task {
      await sendMessage(
        conversationID: id, text: turn.text, from: turn.from, speakers: turn.speakers,
        hops: turn.hops)
    }
  }
  private struct Handoff: Decodable {
    let handoff: Body
    struct Body: Decodable {
      let to: String
      let message: String
    }
  }
  /// Delivers a message_bot call: into the same group when the target is a member,
  /// otherwise into the target bot's newest one-bot chat, like a DM between bots.
  private func deliver(_ handoff: Handoff.Body, from id: UUID) {
    let store = ConversationStore.shared
    guard let run = runs[id], let sender = BotLibrary.shared.bot(id: run.botID) else { return }
    guard run.hops < Self.maxHops else {
      runs[id]?.failure = "Hand-off limit (\(Self.maxHops)) reached; \(handoff.to) was not messaged."
      return
    }
    guard let target = BotLibrary.shared.bots.first(where: { $0.name == handoff.to }) else { return }
    let chat: Conversation
    var text = "Message from \(sender.name): \(handoff.message)"
    if let group = store.conversation(id: id), group.isGroup, group.memberIDs.contains(target.id) {
      chat = group
      text = "@\(target.name) \(handoff.message)"
    } else if let existing = store.conversations.first(where: {
      $0.botID == target.id && !$0.isGroup
    }) {
      chat = existing
    } else {
      let shown = store.selectedConversationID
      chat = store.createConversation(bot: target)
      store.selectConversation(shown)
    }
    let turn = Turn(text: text, from: sender.id, speakers: [target.id], hops: run.hops + 1)
    if isRunning(conversationID: chat.id) {
      inbox[chat.id, default: []].append(turn)
    } else {
      start(turn, in: chat.id)
    }
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
      do { try worker(id)?.send(.lastAssistantText) } catch {
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
      } else if event.method == "notify", let text = event.message?.text,
        let handoff = try? JSONDecoder().decode(Handoff.self, from: Data(text.utf8))
      {
        deliver(handoff.handoff, from: id)
      } else if event.method == "input", event.title == "maestro.calendar" {
        let worker = worker(id)
        Task {
          let reply = await MacCalendar.handle(event.placeholder ?? "")
          do { try worker?.send(.input(id: requestID, value: reply)) } catch {
            fail(id, error.localizedDescription)
          }
        }
      } else if ["input", "editor", "select"].contains(event.method ?? "") {
        do { try worker(id)?.send(.cancelInput(id: requestID)) } catch {
          fail(id, error.localizedDescription)
        }
      }
    default: break
    }
  }
}
