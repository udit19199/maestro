//
//  AppShell.swift
//  zoro
//
//  Created by Udit Agarwal on 01/07/26.
//

import SwiftUI

struct AppShell: View {
    @ObservedObject private var conversationStore = ConversationStore.shared
    @State private var showSettings = false
    @State private var showNewChatSheet = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ConversationSidebarView(showNewChatSheet: $showNewChatSheet, showSettings: $showSettings)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 280)
        } detail: {
            VStack(spacing: 0) {
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
        .onReceive(NotificationCenter.default.publisher(for: .zoroSettings)) { _ in
            showSettings = true
        }
        .onChange(of: conversationStore.selectedConversationID) { _, _ in showSettings = false }
        .onReceive(NotificationCenter.default.publisher(for: .zoroNewChat)) { _ in
            showSettings = false
            showNewChatSheet = true
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if showSettings {
            VStack(spacing: 0) {
                HStack {
                    Button("Back") { showSettings = false }
                    Text("Settings").font(.headline)
                    Spacer()
                }.padding()
                SettingsView()
            }
        } else if let selectedID = conversationStore.selectedConversationID,
           conversationStore.conversation(id: selectedID) != nil {
            ChatView(conversationID: selectedID)
        } else {
            HomeView()
        }
    }
}

#Preview {
    AppShell()
}
