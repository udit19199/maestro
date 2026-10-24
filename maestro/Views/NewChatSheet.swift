//
//  NewChatSheet.swift
//  maestro
//
//  Created by Udit Agarwal on 01/07/26.
//

import SwiftUI

struct NewChatSheet: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject private var conversationStore = ConversationStore.shared

  @ObservedObject private var bots = BotLibrary.shared
  @State private var selectedBot: UUID?

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("New Chat")
        .font(.title2)
        .fontWeight(.semibold)

      Text("Choose a bot to start with. You can switch bots later.")
        .font(.subheadline)
        .foregroundStyle(.secondary)

      if let error = bots.loadError { Text(error).foregroundStyle(.red) }

      Picker("Bot", selection: $selectedBot) {
        ForEach(bots.bots) { Text($0.name).tag(Optional($0.id)) }
      }

      HStack {
        Spacer()
        Button("Cancel") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)

        Button("Create") {
          if let bot = bots.bots.first(where: { $0.id == selectedBot }) {
            conversationStore.createConversation(bot: bot)
          }
          dismiss()
        }
        .disabled(selectedBot == nil)
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
      }
    }
    .onAppear { selectedBot = bots.bots.first?.id }
    .padding(24)
    .frame(width: 480)
  }
}
