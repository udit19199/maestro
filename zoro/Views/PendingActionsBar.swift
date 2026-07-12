//
//  PendingActionsBar.swift
//  zoro
//
//  Global human-in-the-loop confirms for irreversible actions.
//

import SwiftUI

struct PendingActionsBar: View {
    @ObservedObject private var workspace = WorkspaceManager.shared
    @ObservedObject private var conversationStore = ConversationStore.shared

    @State private var isSendingMail = false
    @State private var isSendingIMessage = false
    @State private var isRunningShell = false
    @State private var isApplyingCalendar = false
    @State private var lastResultMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            if let pending = workspace.pendingMailSend {
                MailSendConfirmPanel(
                    pending: pending.panelModel,
                    isSending: isSendingMail,
                    onSend: { confirmMail(pending) },
                    onCancel: { workspace.clearPendingMailSend() }
                )
            }

            if let pending = workspace.pendingIMessageSend {
                confirmCard(
                    title: "Send this iMessage?",
                    details: [
                        ("To", pending.recipient),
                        ("Body", pending.preview)
                    ],
                    confirmTitle: isSendingIMessage ? "Sending…" : "Send",
                    isBusy: isSendingIMessage,
                    onCancel: { workspace.clearPendingIMessageSend() },
                    onConfirm: { confirmIMessage(pending) }
                )
            }

            if let pending = workspace.pendingShellCommand {
                confirmCard(
                    title: "Run this terminal command?",
                    monospacedBody: pending.command,
                    footnote: pending.runInBackground ? "Will run in background after confirm." : nil,
                    confirmTitle: isRunningShell ? "Running…" : "Run",
                    isBusy: isRunningShell,
                    onCancel: { workspace.clearPendingShellCommand() },
                    onConfirm: { confirmShell(pending) }
                )
            }

            if !workspace.pendingCalendarProposals.isEmpty {
                calendarProposalsPanel
            }

            if let pending = workspace.pendingReminder {
                confirmCard(
                    title: "Create this reminder?",
                    details: [
                        ("Title", pending.title),
                        ("Due", pending.dueDate ?? "(none)"),
                        ("Notes", pending.notes ?? "")
                    ].filter { !$0.1.isEmpty },
                    confirmTitle: isApplyingCalendar ? "Saving…" : "Create",
                    isBusy: isApplyingCalendar,
                    onCancel: { workspace.clearPendingReminder() },
                    onConfirm: { confirmReminder(pending) }
                )
            }

            if let pending = workspace.pendingCalendarDelete {
                confirmCard(
                    title: "Delete this calendar event?",
                    details: [("Event", pending.title)],
                    confirmTitle: isApplyingCalendar ? "Deleting…" : "Delete",
                    isBusy: isApplyingCalendar,
                    destructive: true,
                    onCancel: { workspace.clearPendingCalendarDelete() },
                    onConfirm: { confirmDelete(pending) }
                )
            }

            if let pending = workspace.pendingReminderComplete {
                confirmCard(
                    title: "Mark reminder complete?",
                    details: [("Reminder", pending.title)],
                    confirmTitle: isApplyingCalendar ? "Saving…" : "Complete",
                    isBusy: isApplyingCalendar,
                    onCancel: { workspace.clearPendingReminderComplete() },
                    onConfirm: { confirmReminderComplete(pending) }
                )
            }

            if let lastResultMessage {
                Text(lastResultMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }
        }
    }

    private var calendarProposalsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Create \(workspace.pendingCalendarProposals.count) calendar event(s)?")
                .font(.subheadline)
                .fontWeight(.semibold)

            ForEach(workspace.pendingCalendarProposals.prefix(5)) { event in
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title).font(.caption).fontWeight(.medium)
                    Text("\(event.startDate) → \(event.endDate)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if workspace.pendingCalendarProposals.count > 5 {
                Text("…and \(workspace.pendingCalendarProposals.count - 5) more")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Cancel") {
                    workspace.clearPendingCalendarProposals()
                }
                .buttonStyle(.bordered)

                Button(isApplyingCalendar ? "Creating…" : "Create events") {
                    confirmCalendarProposals()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isApplyingCalendar)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding([.horizontal, .top])
    }

    private func confirmCard(
        title: String,
        details: [(String, String)] = [],
        monospacedBody: String? = nil,
        footnote: String? = nil,
        confirmTitle: String,
        isBusy: Bool,
        destructive: Bool = false,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)

            ForEach(Array(details.enumerated()), id: \.offset) { _, pair in
                labeled(pair.0, pair.1)
            }

            if let monospacedBody {
                Text(monospacedBody)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if let footnote {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)

                Button(confirmTitle, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .tint(destructive ? .red : nil)
                    .disabled(isBusy)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding([.horizontal, .top])
    }

    private func labeled(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
                .textSelection(.enabled)
        }
    }

    private func confirmMail(_ pending: PendingMailSendRequest) {
        guard !isSendingMail else { return }
        isSendingMail = true
        Task {
            do {
                try await MailManager.shared.confirmPendingSend(pending)
                await MainActor.run {
                    workspace.clearPendingMailSend()
                    finish("Email sent to \(pending.to).", conversationID: pendingConversationHint())
                    isSendingMail = false
                }
            } catch {
                await MainActor.run {
                    lastResultMessage = "Failed to send email: \(error.localizedDescription)"
                    isSendingMail = false
                }
            }
        }
    }

    private func confirmIMessage(_ pending: PendingIMessageSend) {
        guard !isSendingIMessage else { return }
        isSendingIMessage = true
        Task {
            let result = await workspace.confirmPendingIMessage(pending)
            await MainActor.run {
                finish(result, conversationID: pending.conversationID)
                isSendingIMessage = false
            }
        }
    }

    private func confirmShell(_ pending: PendingShellCommand) {
        guard !isRunningShell else { return }
        isRunningShell = true
        Task {
            let result = await workspace.confirmPendingShell(pending)
            await MainActor.run {
                finish("Shell result:\n\(result)", conversationID: pending.conversationID)
                isRunningShell = false
            }
        }
    }

    private func confirmCalendarProposals() {
        guard !isApplyingCalendar else { return }
        let proposals = workspace.pendingCalendarProposals
        isApplyingCalendar = true
        Task {
            let result = await CalendarEventApplier.apply(proposals: proposals)
            await MainActor.run {
                workspace.clearPendingCalendarProposals()
                finish(result, conversationID: pendingConversationHint())
                isApplyingCalendar = false
            }
        }
    }

    private func confirmReminder(_ pending: PendingReminderProposal) {
        guard !isApplyingCalendar else { return }
        isApplyingCalendar = true
        Task {
            let result = await CalendarConfirmations.createReminder(pending)
            await MainActor.run {
                workspace.clearPendingReminder()
                finish(result, conversationID: pending.conversationID)
                isApplyingCalendar = false
            }
        }
    }

    private func confirmDelete(_ pending: PendingCalendarDelete) {
        guard !isApplyingCalendar else { return }
        isApplyingCalendar = true
        Task {
            let result = await CalendarConfirmations.deleteEvent(pending)
            await MainActor.run {
                workspace.clearPendingCalendarDelete()
                finish(result, conversationID: pending.conversationID)
                isApplyingCalendar = false
            }
        }
    }

    private func confirmReminderComplete(_ pending: PendingReminderComplete) {
        guard !isApplyingCalendar else { return }
        isApplyingCalendar = true
        Task {
            let result = await CalendarConfirmations.completeReminder(pending)
            await MainActor.run {
                workspace.clearPendingReminderComplete()
                finish(result, conversationID: pending.conversationID)
                isApplyingCalendar = false
            }
        }
    }

    private func finish(_ text: String, conversationID: UUID?) {
        lastResultMessage = String(text.prefix(240))
        appendAssistantNote(conversationID: conversationID, text: text)
    }

    private func pendingConversationHint() -> UUID? {
        conversationStore.selectedConversationID ?? workspace.activeConversationID
    }

    private func appendAssistantNote(conversationID: UUID?, text: String) {
        guard let conversationID else { return }
        conversationStore.appendMessage(
            to: conversationID,
            message: StoredMessage(role: .assistant, content: text)
        )
    }
}
