//
//  ConversationSidebarView.swift
//  zoro
//
//  Created by Udit Agarwal on 01/07/26.
//

import SwiftUI

struct ConversationSidebarView: View {
    @Binding var showNewChatSheet: Bool
    @ObservedObject private var conversationStore = ConversationStore.shared

    var body: some View {
        List(selection: $conversationStore.selectedConversationID) {
            Section {
                Button {
                    conversationStore.selectConversation(nil)
                } label: {
                    Label("Briefing", systemImage: "sun.max")
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

    @ViewBuilder
    private func conversationRows(_ conversations: [Conversation]) -> some View {
        ForEach(conversations) { conversation in
            ConversationRow(conversation: conversation)
                .tag(conversation.id)
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
            AgentRunner.shared.invalidateSession(for: id)
            conversationStore.deleteConversation(id)
        }
    }
}

private struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(conversation.title)
                    .lineLimit(1)
                    .font(.body)
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                agentBadge(for: conversation.agentType)
                if conversation.source == .imessage {
                    Text("iMessage")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func agentBadge(for agentType: AgentType) -> some View {
        Label(agentType.displayName, systemImage: agentType.systemImage)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(agentType == .default ? 0.08 : 0.15))
            .foregroundStyle(agentType == .default ? Color.secondary : Color.accentColor)
            .clipShape(Capsule())
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
