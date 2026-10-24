import SwiftUI

struct HomeView: View {
  @ObservedObject private var bots = BotLibrary.shared
  @ObservedObject private var store = ConversationStore.shared
  @State private var prompt = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("Maestro").font(.largeTitle).fontWeight(.semibold)
      Text("Choose a bot and start a conversation.").foregroundStyle(.secondary)
      if let error = bots.loadError { Text(error).foregroundStyle(.red) }
      ForEach(bots.bots) { bot in
        Button(bot.name) { store.createConversation(bot: bot) }
      }
      Spacer()
      ComposerView(
        placeholder: "Start a conversation...", isRunning: false,
        isDisabled: bots.bots.isEmpty, text: $prompt
      ) {
        guard let bot = bots.bots.first else { return }
        let conversation = store.createConversation(bot: bot)
        let message = prompt
        prompt = ""
        Task { await PiSessions.shared.sendMessage(conversationID: conversation.id, text: message) }
      }
    }.padding(24)
  }
}
