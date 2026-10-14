//
//  ConversationSidebarView.swift
//  zoro
//
//  Created by Udit Agarwal on 01/07/26.
//

import SwiftUI

struct ConversationSidebarView: View {
  @Binding var showNewChatSheet: Bool
  @Binding var showSettings: Bool
  @ObservedObject private var conversationStore = ConversationStore.shared
  @State private var isSettingsHovering = false

  var body: some View {
    List(selection: $conversationStore.selectedConversationID) {
      Section {
        Button {
          showSettings = false
          conversationStore.selectConversation(nil)
        } label: {
          Label("Home", systemImage: "house")
        }
        .buttonStyle(.plain)
        .tag(UUID?.none)
      }

      if !groupedConversations.today.isEmpty {
        Section("Today") {
          conversationRows(groupedConversations.today)
        }
      }

      if !groupedConversations.yesterday.isEmpty {
        Section("Yesterday") {
          conversationRows(groupedConversations.yesterday)
        }
      }

      if !groupedConversations.previous.isEmpty {
        Section("Previous 7 Days") {
          conversationRows(groupedConversations.previous)
        }
      }

      if !groupedConversations.older.isEmpty {
        Section("Older") {
          conversationRows(groupedConversations.older)
        }
      }
    }
    .listStyle(.sidebar)
    .navigationTitle("Zoro")
    .safeAreaInset(edge: .bottom, spacing: 0) {
      settingsFooter
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          showNewChatSheet = true
        } label: {
          Label("New Chat", systemImage: "plus")
        }
        .help("New chat")
      }
    }
  }

  private var settingsFooter: some View {
    VStack(spacing: 0) {
      Divider()
      Button {
        NotificationCenter.default.post(name: .zoroSettings, object: nil)
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "gearshape")
            .font(.system(size: 13))
            .frame(width: 18)
          Text("Settings")
            .font(.body)
          Spacer(minLength: 0)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.primary.opacity(isSettingsHovering ? 0.08 : 0))
        )
      }
      .buttonStyle(.plain)
      .onHover { isSettingsHovering = $0 }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .help("Configure providers, models, and MCP servers")
      .accessibilityLabel("Settings")
      .accessibilityHint("Configure providers, models, and MCP servers")
    }
  }

  @ViewBuilder
  private func conversationRows(_ conversations: [Conversation]) -> some View {
    ForEach(conversations) { conversation in
      ConversationRow(conversation: conversation)
        .tag(conversation.id)
        .contextMenu {
          Button("Delete Chat", role: .destructive) {
            conversationStore.deleteConversation(conversation.id)
          }
        }
    }
    .onDelete { offsets in
      deleteConversations(at: offsets, from: conversations)
    }
  }

  private var groupedConversations: ConversationGroups {
    ConversationGroups(conversations: conversationStore.conversations)
  }

  private func deleteConversations(at offsets: IndexSet, from group: [Conversation]) {
    for index in offsets {
      let id = group[index].id
      conversationStore.deleteConversation(id)
    }
  }
}

private struct ConversationRow: View {
  let conversation: Conversation
  @ObservedObject private var bots = BotLibrary.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text(conversation.title)
          .lineLimit(1)
          .font(.body)
        Spacer(minLength: 0)
      }
      HStack(spacing: 6) {
        Label(
          bots.bot(id: conversation.botID)?.name ?? "Unavailable bot",
          systemImage: "person.crop.rectangle.stack"
        ).font(.caption2).foregroundStyle(.secondary)

      }
    }
    .padding(.vertical, 2)
  }

}

private struct ConversationGroups {
  let today: [Conversation]
  let yesterday: [Conversation]
  let previous: [Conversation]
  let older: [Conversation]

  init(conversations: [Conversation]) {
    let calendar = Calendar.current
    let startOfToday = calendar.startOfDay(for: Date())
    let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)
    let startOfWeek = calendar.date(byAdding: .day, value: -7, to: startOfToday)

    var todayList: [Conversation] = []
    var yesterdayList: [Conversation] = []
    var previousList: [Conversation] = []
    var olderList: [Conversation] = []

    for conversation in conversations {
      let day = calendar.startOfDay(for: conversation.updatedAt)
      if day == startOfToday {
        todayList.append(conversation)
      } else if let startOfYesterday, day == startOfYesterday {
        yesterdayList.append(conversation)
      } else if let startOfWeek, day >= startOfWeek {
        previousList.append(conversation)
      } else {
        olderList.append(conversation)
      }
    }

    today = todayList
    yesterday = yesterdayList
    previous = previousList
    older = olderList
  }
}
