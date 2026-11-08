import SwiftUI

struct ChatView: View {
  let conversationID: UUID
  @ObservedObject private var store = ConversationStore.shared
  @ObservedObject private var runner = PiSessions.shared
  @ObservedObject private var bots = BotLibrary.shared
  @State private var prompt = ""

  var body: some View {
    if let conversation = store.conversation(id: conversationID) {
      VStack(spacing: 0) {
        HStack {
          if conversation.isGroup {
            Menu {
              ForEach(bots.bots) { bot in
                Toggle(
                  bot.name,
                  isOn: Binding(
                    get: { conversation.memberIDs.contains(bot.id) },
                    set: { on in
                      var members = conversation.memberIDs
                      if on { members.append(bot.id) } else { members.removeAll { $0 == bot.id } }
                      store.setMembers(members, for: conversationID)
                    })
                )
                .disabled(
                  conversation.memberIDs.contains(bot.id)
                    ? conversation.memberIDs.count <= 2 : conversation.memberIDs.count >= 6)
              }
            } label: {
              Label(
                conversation.memberIDs.map { bots.bot(id: $0)?.name ?? "Unavailable bot" }
                  .joined(separator: ", "), systemImage: "person.2")
            }
            .disabled(runner.isRunning(conversationID: conversationID))
            .help("Change who is in this group")
          } else {
            Picker(
              "Bot",
              selection: Binding(
                get: { conversation.botID },
                set: { store.selectBot($0, for: conversationID) }
              )
            ) {
              if bots.bot(id: conversation.botID) == nil {
                Text("Unavailable bot").tag(conversation.botID)
              }
              ForEach(bots.bots) { Text($0.name).tag($0.id) }
            }
            .disabled(runner.isRunning(conversationID: conversationID))
          }
          Spacer()
          Button("Delete Chat", role: .destructive) { store.deleteConversation(conversationID) }
          if runner.isRunning(conversationID: conversationID) {
            Button("Stop") { runner.stopConversation(conversationID) }
          }
        }.padding()
        if let approval = runner.approval(for: conversationID) {
          VStack(alignment: .leading, spacing: 8) {
            Text(approval.title).font(.headline)
            ScrollView { Text(approval.message).font(.caption).textSelection(.enabled) }.frame(
              maxHeight: 150)
            HStack {
              Button("Approve") { runner.approve(conversationID, allowed: true) }
              Button("Deny") { runner.approve(conversationID, allowed: false) }
            }
          }.padding()
        }
        Divider()
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(spacing: 16) {
              ForEach(conversation.messages) { message in
                MessageBubble(message: message).id(message.id)
              }
            }.padding()
          }
          .onChange(of: conversation.messages.last?.content) { _, _ in
            if let id = conversation.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
          }
        }
        ComposerView(
          placeholder: conversation.isGroup
            ? "Message the group (type @Name to pick a bot)..." : "Message this bot...",
          isRunning: runner.isRunning(conversationID: conversationID),
          isDisabled: bots.bot(id: conversation.botID) == nil, text: $prompt
        ) {
          let message = prompt
          prompt = ""
          Task { await runner.sendMessage(conversationID: conversationID, text: message) }
        }
      }
    } else {
      ContentUnavailableView("Conversation not found", systemImage: "bubble.left.and.bubble.right")
    }
  }
}
