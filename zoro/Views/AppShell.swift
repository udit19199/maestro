//
//  AppShell.swift
//  zoro
//
//  Created by Udit Agarwal on 01/07/26.
//

import SwiftUI

struct AppShell: View {
    @ObservedObject private var conversationStore = ConversationStore.shared
    @State private var showNewChatSheet = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ConversationSidebarView(showNewChatSheet: $showNewChatSheet)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 280)
        } detail: {
            VStack(spacing: 0) {
                PendingActionsBar()
                detailContent
            }
        }
        .sheet(isPresented: $showNewChatSheet) {
            NewChatSheet()
        }
        .frame(minWidth: 800, minHeight: 500)
        .onAppear {
            conversationStore.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .zoroNewChat)) { _ in
            showNewChatSheet = true
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if let selectedID = conversationStore.selectedConversationID,
           conversationStore.conversation(id: selectedID) != nil {
            ChatView(conversationID: selectedID)
        } else {
            BriefingHomeView()
        }
    }
}

#Preview {
    AppShell()
}
