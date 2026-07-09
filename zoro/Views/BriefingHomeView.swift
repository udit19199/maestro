//
//  BriefingHomeView.swift
//  zoro
//

import SwiftUI

struct BriefingHomeView: View {
    @ObservedObject private var conversationStore = ConversationStore.shared
    @ObservedObject private var agentRunner = AgentRunner.shared
    @ObservedObject private var briefingService = BriefingService.shared
    @ObservedObject private var cleanupService = CleanupReviewService.shared

    @State private var prompt = ""
    @State private var showCleanupReview = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    greetingHeader

                    HStack {
                        if let refreshed = briefingService.lastRefreshedAt {
                            Text("Updated \(refreshed.formatted(date: .omitted, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            Task { await briefingService.refresh() }
                        } label: {
                            Label("Refresh briefing", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .disabled(briefingService.isRefreshing)
                    }

                    briefingSection(title: "Yesterday", content: briefingService.yesterdayRecap)

                    BriefingInboxSection(
                        digest: briefingService.inboxDigest,
                        items: briefingService.priorityUnread,
                        unreadTotal: briefingService.inboxUnreadTotal,
                        pendingCleanupCount: briefingService.pendingCleanupCount,
                        state: briefingService.inboxState,
                        onSelectItem: { item in
                            prompt = item.composerPrompt
                        },
                        onReviewCleanup: {
                            Task {
                                await cleanupService.scanCandidates()
                                showCleanupReview = true
                            }
                        },
                        onConnectAccounts: {
                            openZoroSettings()
                        }
                    )

                    briefingSection(title: "Today", content: briefingService.todayCalendarSummary)

                    suggestionsSection
                }
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            .background(Color(NSColor.textBackgroundColor))

            ComposerView(
                style: .slim,
                placeholder: "Ask a follow-up…",
                isRunning: false,
                isDisabled: false,
                text: $prompt,
                onSend: sendFromHome
            )
        }
        .task {
            await briefingService.refresh()
        }
        .sheet(isPresented: $showCleanupReview) {
            CleanupReviewSheet(
                items: cleanupService.pendingItems,
                isArchiving: cleanupService.isArchiving,
                onArchiveAll: {
                    Task {
                        await cleanupService.archiveAll()
                        await briefingService.refresh()
                        showCleanupReview = false
                    }
                },
                onSkip: {
                    showCleanupReview = false
                }
            )
        }
    }

    private var greetingHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greetingText)
                .font(.system(size: 28, weight: .semibold))
            Text(formattedToday)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private var formattedToday: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        return formatter.string(from: Date())
    }

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Suggestions")
                .font(.headline)
            ForEach(Array(briefingService.suggestions.enumerated()), id: \.offset) { _, suggestion in
                Text("• \(suggestion)")
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    private func briefingSection(title: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(content)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    private func sendFromHome() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        prompt = ""

        let conversation = conversationStore.createConversation(agentType: .default)
        Task {
            await agentRunner.sendMessage(conversationID: conversation.id, text: text)
        }
    }
}
