//
//  NewChatSheet.swift
//  zoro
//
//  Created by Udit Agarwal on 01/07/26.
//

import SwiftUI

struct NewChatSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var conversationStore = ConversationStore.shared

    @State private var selectedAgent: AgentType = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("New Chat")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Choose an agent for this conversation. You can't switch agents mid-thread in v1.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(AgentType.allCases) { agent in
                    Button {
                        selectedAgent = agent
                    } label: {
                        Label(agent.displayName, systemImage: agent.systemImage)
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .background(
                        Capsule()
                            .fill(selectedAgent == agent ? Color.accentColor : Color(NSColor.controlBackgroundColor))
                    )
                    .foregroundStyle(selectedAgent == agent ? .white : .secondary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Create") {
                    conversationStore.createConversation(agentType: selectedAgent)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
