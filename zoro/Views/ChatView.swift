//
//  ChatView.swift
//  zoro
//

import SwiftUI

struct ChatView: View {
    let conversationID: UUID

    @ObservedObject private var conversationStore = ConversationStore.shared
    @ObservedObject private var workspace = WorkspaceManager.shared
    @ObservedObject private var agentRunner = AgentRunner.shared
    @ObservedObject private var profileStore = ProfileStore.shared

    @State private var prompt = ""
    @State private var handoffSuggestion: AgentHandoffDetector.Suggestion?
    @State private var isApplyingCalendarEvents = false
    @State private var isSendingMail = false

    private var conversation: Conversation? {
        conversationStore.conversation(id: conversationID)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let conversation {
                chatHeader(conversation: conversation)

                if profileStore.showMemoryUpdatedBanner {
                    memoryUpdatedBanner
                }

                if let handoffSuggestion, conversation.agentType == .default {
                    agentHandoffBanner(handoffSuggestion)
                }

                if !workspace.pendingCalendarProposals.isEmpty, conversation.agentType == .planner {
                    plannerConfirmationPanel
                }

                if let pendingMailSend = workspace.pendingMailSend {
                    MailSendConfirmPanel(
                        pending: pendingMailSend.panelModel,
                        isSending: isSendingMail,
                        onSend: { confirmMailSend(pendingMailSend) },
                        onCancel: { workspace.clearPendingMailSend() }
                    )
                }

                if !workspace.activeTodos.isEmpty {
                    executionPlanPanel
                }

                if !workspace.researchSteps.isEmpty {
                    researchProgressPanel
                }

                messageList(messages: conversation.messages)

                ComposerView(
                    style: .full,
                    placeholder: composerPlaceholder,
                    isRunning: agentRunner.isRunning(conversationID: conversationID),
                    isDisabled: false,
                    text: $prompt,
                    onSend: sendMessage
                )
            } else {
                ContentUnavailableView("Conversation not found", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .onChange(of: conversation?.messages.count) { _, _ in
            updateHandoffSuggestion()
        }
    }

    private var memoryUpdatedBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "brain.head.profile")
                .foregroundStyle(.secondary)
            Text("Memory updated")
                .font(.subheadline)
            Spacer()
            Button("Review") {
                openZoroSettings()
                profileStore.dismissMemoryBanner()
            }
            .buttonStyle(.borderless)
            Button {
                profileStore.dismissMemoryBanner()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func agentHandoffBanner(_ suggestion: AgentHandoffDetector.Suggestion) -> some View {
        HStack(spacing: 12) {
            Text(suggestion.message)
                .font(.subheadline)
            Spacer()
            Button("Start \(suggestion.agentType.displayName) chat") {
                conversationStore.createConversation(agentType: suggestion.agentType)
                handoffSuggestion = nil
            }
            .buttonStyle(.borderedProminent)
            Button {
                handoffSuggestion = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var plannerConfirmationPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Apply \(workspace.pendingCalendarProposals.count) event\(workspace.pendingCalendarProposals.count == 1 ? "" : "s") to calendar?")
                .font(.subheadline)
                .fontWeight(.semibold)

            ForEach(workspace.pendingCalendarProposals) { proposal in
                VStack(alignment: .leading, spacing: 2) {
                    Text(proposal.title)
                        .font(.caption)
                        .fontWeight(.medium)
                    Text("\(proposal.startDate) → \(proposal.endDate)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Cancel") {
                    workspace.clearPendingCalendarProposals()
                }
                .buttonStyle(.bordered)

                Button(isApplyingCalendarEvents ? "Applying…" : "Apply to Calendar") {
                    applyCalendarProposals()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isApplyingCalendarEvents)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding([.horizontal, .top])
    }

    private func chatHeader(conversation: Conversation) -> some View {
        HStack(spacing: 12) {
            Label(conversation.agentType.displayName, systemImage: conversation.agentType.systemImage)
                .font(.headline)

            Text(conversation.agentType.displayName)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(conversation.agentType == .default ? 0.1 : 0.18))
                .foregroundStyle(conversation.agentType == .default ? Color.secondary : Color.accentColor)
                .clipShape(Capsule())

            if conversation.source == .imessage {
                Text("iMessage")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(Capsule())
            }

            Spacer()

            Circle()
                .fill(modelStatusColor)
                .frame(width: 8, height: 8)
                .help(modelStatusHelp)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var modelStatusColor: Color {
        switch conversation?.agentType {
        case .default:
            return .green
        default:
            let preferred = ModelType.preferredForSpecializedAgents()
            return preferred == .system ? .orange : .green
        }
    }

    private var modelStatusHelp: String {
        guard let agent = conversation?.agentType else { return "Model status" }
        switch agent {
        case .default:
            return "Using \(workspace.selectedModelType.rawValue)"
        default:
            let preferred = ModelType.preferredForSpecializedAgents()
            return "Using \(preferred.rawValue)"
        }
    }

    private var composerPlaceholder: String {
        if let question = workspace.activeClarificationQuestion {
            return "Zoro needs reply: \(question)"
        }
        return "Ask anything, search the web, check your calendar…"
    }

    private var executionPlanPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Execution Plan")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            ForEach(workspace.activeTodos) { todo in
                HStack(spacing: 8) {
                    Image(systemName: todoIcon(for: todo.status))
                        .font(.system(size: 11))
                        .foregroundStyle(todoColor(for: todo.status))
                    Text(todo.content)
                        .font(.caption)
                        .strikethrough(todo.status == "completed")
                        .foregroundStyle(todo.status == "completed" ? .secondary : .primary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding([.horizontal, .top])
    }

    private var researchProgressPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Research Progress")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            ForEach(workspace.researchSteps) { step in
                HStack(spacing: 8) {
                    Image(systemName: researchStepIcon(for: step.status))
                        .font(.system(size: 11))
                        .foregroundStyle(researchStepColor(for: step.status))
                    Text(step.title)
                        .font(.caption)
                        .strikethrough(step.status == "completed")
                        .foregroundStyle(step.status == "completed" ? .secondary : .primary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding([.horizontal, .top])
    }

    private func messageList(messages: [StoredMessage]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .padding()
            }
            .background(Color(NSColor.textBackgroundColor))
            .onChange(of: messages.count) { _, _ in
                scrollToBottom(proxy: proxy, messages: messages)
            }
            .onChange(of: messages.last?.content) { _, _ in
                scrollToBottom(proxy: proxy, messages: messages)
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy, messages: [StoredMessage]) {
        if let lastMessage = messages.last {
            withAnimation {
                proxy.scrollTo(lastMessage.id, anchor: .bottom)
            }
        }
    }

    private func sendMessage() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        prompt = ""

        Task {
            await agentRunner.sendMessage(conversationID: conversationID, text: text)
            updateHandoffSuggestion()
        }
    }

    private func updateHandoffSuggestion() {
        guard let conversation, conversation.agentType == .default else {
            handoffSuggestion = nil
            return
        }
        if let lastUser = conversation.messages.last(where: { $0.role == .user }) {
            handoffSuggestion = AgentHandoffDetector.suggest(for: lastUser.content)
        }
    }

    private func applyCalendarProposals() {
        let proposals = workspace.pendingCalendarProposals
        guard !proposals.isEmpty else { return }
        isApplyingCalendarEvents = true

        Task {
            let result = await CalendarEventApplier.apply(proposals: proposals)
            await MainActor.run {
                workspace.clearPendingCalendarProposals()
                conversationStore.appendMessage(
                    to: conversationID,
                    message: StoredMessage(role: .assistant, content: result)
                )
                isApplyingCalendarEvents = false
            }
        }
    }

    private func confirmMailSend(_ pending: PendingMailSendRequest) {
        guard !isSendingMail else { return }
        isSendingMail = true

        Task {
            do {
                try await MailManager.shared.confirmPendingSend(pending)
                await MainActor.run {
                    workspace.clearPendingMailSend()
                    conversationStore.appendMessage(
                        to: conversationID,
                        message: StoredMessage(
                            role: .assistant,
                            content: "Email sent to \(pending.to) from \(pending.accountLabel)."
                        )
                    )
                    isSendingMail = false
                }
            } catch {
                await MainActor.run {
                    conversationStore.appendMessage(
                        to: conversationID,
                        message: StoredMessage(
                            role: .assistant,
                            content: "Failed to send email: \(error.localizedDescription)"
                        )
                    )
                    isSendingMail = false
                }
            }
        }
    }

    private func todoIcon(for status: String) -> String {
        switch status {
        case "completed": return "checkmark.circle.fill"
        case "in_progress": return "arrow.triangle.2.circlepath.circle.fill"
        case "cancelled": return "xmark.circle.fill"
        default: return "circle"
        }
    }

    private func todoColor(for status: String) -> Color {
        switch status {
        case "completed": return .green
        case "in_progress": return .blue
        case "cancelled": return .gray
        default: return .secondary
        }
    }

    private func researchStepIcon(for status: String) -> String {
        switch status {
        case "completed": return "checkmark.circle.fill"
        case "in_progress": return "arrow.triangle.2.circlepath.circle.fill"
        case "failed": return "exclamationmark.circle.fill"
        default: return "circle"
        }
    }

    private func researchStepColor(for status: String) -> Color {
        switch status {
        case "completed": return .green
        case "in_progress": return .blue
        case "failed": return .red
        default: return .secondary
        }
    }
}
