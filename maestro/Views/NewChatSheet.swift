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
  // In pick order; the first bot leads a group.
  @State private var picked: [UUID] = []

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("New Chat")
        .font(.title2)
        .fontWeight(.semibold)

      Text("Pick one bot, or two to six for a group chat. The first bot you pick leads the group.")
        .font(.subheadline)
        .foregroundStyle(.secondary)

      if let error = bots.loadError { Text(error).foregroundStyle(.red) }

      ForEach(bots.bots) { bot in
        Toggle(
          bot.name,
          isOn: Binding(
            get: { picked.contains(bot.id) },
            set: { on in
              if on { picked.append(bot.id) } else { picked.removeAll { $0 == bot.id } }
            })
        )
        .disabled(picked.count >= 6 && !picked.contains(bot.id))
      }

      HStack {
        Spacer()
        Button("Cancel") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)

        Button("Create") {
          if let bot = picked.first.flatMap(bots.bot(id:)) {
            conversationStore.createConversation(bot: bot, extraBotIDs: Array(picked.dropFirst()))
          }
          dismiss()
        }
        .disabled(picked.isEmpty)
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
      }
    }
    .onAppear { picked = bots.bots.first.map { [$0.id] } ?? [] }
    .padding(24)
    .frame(width: 480)
  }
}
