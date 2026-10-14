import Foundation

@main
struct BotChatsCheck {
  @MainActor static func main() async throws {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Zoro")
    precondition(base.path.hasPrefix("/tmp/zoro-bot-chats."), "Run through check-bot-chats.sh")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let storage = base.appendingPathComponent("conversations.json")
    let first = BotDefinition(name: "First", systemPrompt: "First instructions")
    let second = BotDefinition(name: "Second", systemPrompt: "Second instructions")
    let remoteID = UUID()
    let legacyID = UUID()
    let messageID = UUID()
    let record: [String: Any] = [
      "id": legacyID.uuidString, "title": "Existing chat",
      "agent": try JSONSerialization.jsonObject(with: JSONEncoder().encode(first)),
      "messages": [["id": messageID.uuidString, "role": "user", "content": "Keep this history"]],
      "createdAt": "2026-10-14T00:00:00Z", "updatedAt": "2026-10-14T00:00:00Z",
    ]
    var remote = record
    remote["id"] = remoteID.uuidString
    remote.removeValue(forKey: "agent")
    remote["agentType"] = "research"
    remote["source"] = "imessage"
    try JSONSerialization.data(withJSONObject: [record, remote]).write(to: storage)

    let store = ConversationStore.shared
    store.load()
    let migrated = store.conversation(id: legacyID)!
    precondition(migrated.messages.first?.content == "Keep this history")
    precondition(
      BotLibrary.shared.bot(id: migrated.botID)?.systemPrompt == "First instructions")
    precondition(store.conversation(id: remoteID)?.allowsMCP == false)
    let firstRPC = try PiRPC(bot: first, conversationID: legacyID, allowMCP: false)
    let secondRPC = try PiRPC(bot: second, conversationID: legacyID, allowMCP: false)
    let firstArgs = firstRPC.process.arguments!
    let secondArgs = secondRPC.process.arguments!
    precondition(
      firstArgs[firstArgs.firstIndex(of: "--append-system-prompt")! + 1].hasPrefix(
        "First instructions"))
    precondition(
      secondArgs[secondArgs.firstIndex(of: "--append-system-prompt")! + 1].hasPrefix(
        "Second instructions")
    )
    precondition(
      firstArgs[firstArgs.firstIndex(of: "--session-dir")! + 1]
        == secondArgs[secondArgs.firstIndex(of: "--session-dir")! + 1])

    // Attached skills reach pi as --skill paths plus a use-skills instruction.
    let skillDir = base.appendingPathComponent("skills/research", isDirectory: true)
    try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
    try Data(
      "---\nname: research\ndescription: Research skill.\n---\n\n# Research\n".utf8
    ).write(to: skillDir.appendingPathComponent("SKILL.md"))
    let skilled = BotDefinition(
      name: "Skilled", systemPrompt: "Skilled instructions",
      skills: [.machine(path: skillDir.path)])
    let skilledRPC = try PiRPC(bot: skilled, conversationID: legacyID, allowMCP: false)
    let skilledArgs = skilledRPC.process.arguments!
    precondition(skilledArgs.contains("--skill"))
    precondition(skilledArgs[skilledArgs.firstIndex(of: "--skill")! + 1] == skillDir.path)
    let skilledPrompt =
      skilledArgs[skilledArgs.firstIndex(of: "--append-system-prompt")! + 1]
    precondition(skilledPrompt.hasPrefix("Skilled instructions"))
    precondition(skilledPrompt.contains("research"))

    // Workspace skills resolve against the conversation folder, which pi runs in.
    let repoDir = base.appendingPathComponent("repo", isDirectory: true)
    let repoSkill = repoDir.appendingPathComponent(".agents/skills/local", isDirectory: true)
    try FileManager.default.createDirectory(at: repoSkill, withIntermediateDirectories: true)
    try Data(
      "---\nname: local\ndescription: Local skill.\n---\n\n# Local\n".utf8
    ).write(to: repoSkill.appendingPathComponent("SKILL.md"))
    let local = BotDefinition(
      name: "Local", systemPrompt: "Local instructions",
      skills: [.workspace(relativePath: ".agents/skills/local")])
    let localRPC = try PiRPC(
      bot: local, workingDirectory: repoDir.path, conversationID: legacyID)
    let localArgs = localRPC.process.arguments!
    precondition(
      localArgs[localArgs.firstIndex(of: "--skill")! + 1] == repoSkill.path)
    precondition(localRPC.process.currentDirectoryURL?.path == repoDir.path)

    // Execution overrides map to --model; Claude Code refuses pi startup.
    let override = BotDefinition(
      name: "Override", systemPrompt: "Override",
      execution: .pi(provider: "openai", model: "gpt-4o"))
    let overrideArgs = try PiRPC(bot: override, conversationID: legacyID).process.arguments!
    precondition(overrideArgs[overrideArgs.firstIndex(of: "--model")! + 1] == "openai/gpt-4o")
    let claude = BotDefinition(
      name: "Claude", systemPrompt: "Claude", execution: .claudeCode(model: "sonnet"))
    var claudeFailed = false
    do { _ = try PiRPC(bot: claude, conversationID: legacyID) } catch { claudeFailed = true }
    precondition(claudeFailed, "Claude Code bots must not start a pi process")

    let secondID = try BotLibrary.shared.importBot(second)
    store.selectBot(secondID, for: legacyID)
    precondition(store.conversation(id: legacyID)?.botID == secondID)
    precondition(store.conversation(id: legacyID)?.messages.first?.id == messageID)
    store.selectBot(UUID(), for: legacyID)
    precondition(store.conversation(id: legacyID)?.botID == secondID)
    store.persistNow()
    let saved =
      try JSONSerialization.jsonObject(with: Data(contentsOf: storage)) as! [[String: Any]]
    precondition(
      saved.allSatisfy {
        $0["agent"] == nil && $0["customAgent"] == nil && $0["agentID"] == nil
          && $0["botID"] != nil
      })
    let botFile = base.appendingPathComponent("bots/\(secondID.uuidString)/definition.json")
    let savedBot = try JSONDecoder().decode(BotDefinition.self, from: Data(contentsOf: botFile))
    precondition(savedBot.id == secondID && savedBot.systemPrompt == "Second instructions")
    store.load()
    precondition(store.conversation(id: legacyID)?.botID == secondID)
    precondition(store.conversation(id: legacyID)?.messages.first?.content == "Keep this history")
    let reply = StoredMessage(
      role: .assistant, content: "Partial reply", botID: secondID, status: .streaming)
    store.appendMessage(to: legacyID, message: reply)
    store.persistNow()
    store.load()
    let interrupted = store.conversation(id: legacyID)!.messages.last!
    precondition(interrupted.status == .interrupted)
    precondition(interrupted.content == "Partial reply" && interrupted.botID == secondID)
    store.updateMessage(
      conversationID: legacyID, messageID: reply.id, content: "Partial reply",
      status: .failed, failure: "Connection lost")
    store.persistNow()
    store.load()
    let failed = store.conversation(id: legacyID)!.messages.last!
    precondition(failed.status == .failed && failed.failure == "Connection lost")
    precondition(failed.content == "Partial reply")
    let legacyBot = try JSONDecoder().decode(
      BotDefinition.self,
      from: Data(
        "{\"id\":\"\(first.id.uuidString)\",\"name\":\"Old\",\"instructions\":\"Help\",\"model\":\"\"}"
          .utf8))
    precondition(legacyBot.execution == nil && legacyBot.systemPrompt == "Help")
    let combined = try JSONDecoder().decode(
      BotDefinition.self,
      from: Data(
        "{\"id\":\"\(first.id.uuidString)\",\"name\":\"Old\",\"instructions\":\"Help\",\"model\":\"openai/gpt-4o\"}"
          .utf8))
    precondition(combined.execution == .pi(provider: "openai", model: "gpt-4o"))
    let chatDecoder = JSONDecoder()
    chatDecoder.dateDecodingStrategy = .iso8601
    let legacyChat = try chatDecoder.decode(
      Conversation.self,
      from: Data(
        "{\"id\":\"\(legacyID.uuidString)\",\"title\":\"Old chat\",\"agentID\":\"\(secondID.uuidString)\",\"messages\":[{\"id\":\"\(messageID.uuidString)\",\"role\":\"user\",\"content\":\"Hi\",\"agentID\":\"\(secondID.uuidString)\"}],\"createdAt\":\"2026-10-14T00:00:00Z\",\"updatedAt\":\"2026-10-14T00:00:00Z\"}"
          .utf8))
    precondition(legacyChat.botID == secondID && legacyChat.messages.first?.botID == secondID)
    let confirmation =
      try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(
          PiCommand.approval(id: "tool-1", allowed: false))) as! [String: Any]
    precondition(confirmation["type"] as? String == "extension_ui_response")
    precondition(confirmation["id"] as? String == "tool-1")
    precondition(confirmation["confirmed"] as? Bool == false)
    let delta = try JSONDecoder().decode(
      PiEvent.self,
      from: Data(
        #"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"Hello"}}"#
          .utf8))
    precondition(delta.assistantMessageEvent?.delta == "Hello")
    let final = try JSONDecoder().decode(
      PiEvent.self,
      from: Data(
        #"{"type":"response","id":"final","success":true,"data":{"text":"Finished"}}"#.utf8))
    precondition(final.data?.text == "Finished")
    let approval = try JSONDecoder().decode(
      PiEvent.self,
      from: Data(
        #"{"type":"extension_ui_request","id":"tool-1","method":"confirm","title":"Approve tool call","message":"Change a page"}"#
          .utf8))
    precondition(approval.message?.text == "Change a page")
    let unknown = try JSONDecoder().decode(
      PiEvent.self,
      from: Data(
        #"{"type":"future_event","message":42,"data":[1,2,3]}"#.utf8))
    precondition(unknown.type == "future_event")
    let catalogRPC = try PiRPC()
    var receivedModels = false
    var transportFailure: String?
    catalogRPC.onEvent = { event in
      if event.id == "models", event.success == true, event.data?.models != nil {
        receivedModels = true
      }
    }
    catalogRPC.onFailure = { transportFailure = $0 }
    try catalogRPC.start()
    try catalogRPC.send(.availableModels)
    for _ in 0..<200 {
      if receivedModels || transportFailure != nil { break }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    catalogRPC.stop()
    precondition(transportFailure == nil, transportFailure ?? "")
    precondition(
      receivedModels, "The installed pi must return a typed model catalog within 10 seconds")
    let isolated = store.createConversation(bot: first)
    await PiSessions.shared.sendMessage(conversationID: isolated.id, text: "/zoro-providers")
    PiSessions.shared.stopConversation(isolated.id)
    precondition(!PiSessions.shared.isRunning(conversationID: isolated.id))
    let terminal = store.conversation(id: isolated.id)!.messages.last!
    precondition(terminal.status == .stopped || terminal.status == .failed)
    precondition(terminal.botID == first.id)
    store.load()
    precondition(store.conversation(id: isolated.id)!.messages.last!.status == terminal.status)
    print(
      "PASS: reply outcomes survive reload; restart marks partial replies interrupted; legacy defaults, pi payloads, and stopping a real process preserve message identity."
    )
    print(
      "PASS: switching bots keeps history; chats save references; per-bot files, skill flags, workspace folders, and execution mapping hold; migration preserves definitions and remote restrictions; reload keeps selection."
    )
  }
}
