//
//  WorkspaceManager.swift
//  zoro
//

import Foundation
import Combine
import FoundationModels

@MainActor
class WorkspaceManager: ObservableObject {
    static let shared = WorkspaceManager()

    @Published var workspaceURL: URL? = nil

    @Published var selectedModelType: ModelType = .openai
    @Published var pendingCalendarProposals: [PlannerEventProposal] = []
    /// Staged side effects — only cleared on confirm/cancel, never on a new chat turn.
    @Published var pendingMailSend: PendingMailSendRequest?
    @Published var pendingIMessageSend: PendingIMessageSend?
    @Published var pendingShellCommand: PendingShellCommand?
    @Published var pendingReminder: PendingReminderProposal?
    @Published var pendingCalendarDelete: PendingCalendarDelete?
    @Published var pendingReminderComplete: PendingReminderComplete?
    @Published var activeClarificationQuestion: String? = nil

    var clarifyContinuation: CheckedContinuation<String, Never>? = nil
    var activeConversationID: UUID?
    var activeAgentType: AgentType?

    private init() {
        WorkspaceBookmarkStore.shared.restoreIfNeeded(into: self)
    }

    func invalidateSessionsForConfigChange() {
        AgentRunner.shared.invalidateAllSessions()
    }

    /// Clears ephemeral agent UI state and invalidates LLM sessions (messages persist).
    func resetSession() {
        AgentRunner.shared.invalidateAllSessions()
        activeTodos = []
        clearResearchSteps()
        pendingCalendarProposals = []
        // Intentionally do not clear pending outbound actions — user must confirm or cancel.
        activeConversationID = nil
        activeAgentType = nil
    }

    func setWorkspaceURL(_ url: URL?) {
        if let previous = workspaceURL {
            previous.stopAccessingSecurityScopedResource()
        }
        workspaceURL = url
        if let url {
            _ = url.startAccessingSecurityScopedResource()
            WorkspaceBookmarkStore.shared.save(url: url)
        } else {
            WorkspaceBookmarkStore.shared.clear()
        }
        invalidateSessionsForConfigChange()
    }

    func setPendingCalendarProposals(_ proposals: [PlannerEventProposal]) {
        pendingCalendarProposals = proposals
    }

    func clearPendingCalendarProposals() {
        pendingCalendarProposals = []
    }

    func setPendingMailSend(_ pending: PendingMailSendRequest) {
        pendingMailSend = pending
    }

    func clearPendingMailSend() {
        pendingMailSend = nil
    }

    func setPendingIMessageSend(_ pending: PendingIMessageSend) {
        pendingIMessageSend = pending
    }

    func clearPendingIMessageSend() {
        pendingIMessageSend = nil
    }

    func setPendingShellCommand(_ pending: PendingShellCommand) {
        pendingShellCommand = pending
    }

    func clearPendingShellCommand() {
        pendingShellCommand = nil
    }

    func setPendingReminder(_ pending: PendingReminderProposal) {
        pendingReminder = pending
    }

    func clearPendingReminder() {
        pendingReminder = nil
    }

    func setPendingCalendarDelete(_ pending: PendingCalendarDelete) {
        pendingCalendarDelete = pending
    }

    func clearPendingCalendarDelete() {
        pendingCalendarDelete = nil
    }

    func setPendingReminderComplete(_ pending: PendingReminderComplete) {
        pendingReminderComplete = pending
    }

    func clearPendingReminderComplete() {
        pendingReminderComplete = nil
    }

    @Generable
    struct TodoItem: Codable, Identifiable, Equatable {
        @Guide(description: "A short, unique identifier for the task step (e.g. 'step_1')")
        let id: String

        @Guide(description: "A description of the step to perform")
        var content: String

        @Guide(description: "Current task status: 'pending', 'in_progress', 'completed', or 'cancelled'")
        var status: String
    }

    @Published var activeTodos: [TodoItem] = []

    struct ResearchStep: Identifiable, Equatable {
        let id: UUID
        let title: String
        var status: String
    }

    @Published var researchSteps: [ResearchStep] = []

    func addResearchStep(_ title: String) -> UUID {
        let id = UUID()
        researchSteps.append(ResearchStep(id: id, title: title, status: "in_progress"))
        return id
    }

    func completeResearchStep(id: UUID) {
        if let index = researchSteps.firstIndex(where: { $0.id == id }) {
            researchSteps[index].status = "completed"
        }
    }

    func failResearchStep(id: UUID) {
        if let index = researchSteps.firstIndex(where: { $0.id == id }) {
            researchSteps[index].status = "failed"
        }
    }

    func clearResearchSteps() {
        researchSteps = []
    }

    func updateTodos(_ newTodos: [TodoItem], merge: Bool) -> [TodoItem] {
        if !merge {
            activeTodos = newTodos
        } else {
            var current = activeTodos
            for item in newTodos {
                if let idx = current.firstIndex(where: { $0.id == item.id }) {
                    current[idx].content = item.content
                    current[idx].status = item.status
                } else {
                    current.append(item)
                }
            }
            activeTodos = current
        }
        return activeTodos
    }

    struct RunningProcess {
        let id: String
        let command: String
        let process: Process
        let outputPipe: Pipe
        let startDate: Date

        var isRunning: Bool {
            process.isRunning
        }

        func getAvailableOutput() -> String {
            let data = outputPipe.fileHandleForReading.availableData
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    @Published var activeProcesses: [String: RunningProcess] = [:]

    func runCommandBackground(_ command: String) throws -> String {
        guard let workspaceURL = workspaceURL else {
            return "Error: No workspace directory selected."
        }

        let process = Process()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.arguments = ["-c", command]
        process.launchPath = "/bin/zsh"
        process.currentDirectoryURL = workspaceURL

        try process.run()

        let taskId = "task_\(UUID().uuidString.prefix(6).lowercased())"
        let running = RunningProcess(
            id: taskId,
            command: command,
            process: process,
            outputPipe: pipe,
            startDate: Date()
        )

        activeProcesses[taskId] = running

        return "Command started in the background. Task ID: \(taskId)\nUse 'get_process_status' with this ID to inspect logs."
    }

    func pruneTerminatedProcesses() {
        activeProcesses = activeProcesses.filter { $0.value.isRunning }
    }

    func runCommand(_ command: String) async throws -> String {
        guard let workspaceURL = workspaceURL else {
            return "Error: No workspace directory selected."
        }

        let process = Process()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.arguments = ["-c", command]
        process.launchPath = "/bin/zsh"
        process.currentDirectoryURL = workspaceURL

        try process.run()

        let finishedInTime = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    process.waitUntilExit()
                    group.leave()
                }
                let result = group.wait(timeout: .now() + SecurityPolicy.shellTimeoutSeconds)
                continuation.resume(returning: result != .timedOut)
            }
        }

        if !finishedInTime {
            process.terminate()
            return "Error: Command timed out after \(Int(SecurityPolicy.shellTimeoutSeconds)) seconds."
        }

        let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
        let output = String(data: data, encoding: .utf8) ?? ""
        return SecurityPolicy.truncateOutput(
            output,
            maxBytes: SecurityPolicy.maxShellOutputBytes,
            suffix: "\n\n[Output truncated at \(SecurityPolicy.maxShellOutputBytes) bytes]"
        )
    }

    func confirmPendingShell(_ pending: PendingShellCommand) async -> String {
        defer { clearPendingShellCommand() }
        do {
            if pending.runInBackground {
                return try runCommandBackground(pending.command)
            }
            return try await runCommand(pending.command)
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    func confirmPendingIMessage(_ pending: PendingIMessageSend) async -> String {
        defer { clearPendingIMessageSend() }
        do {
            try await IMessageDirectSender.send(
                recipient: pending.recipient,
                text: pending.text,
                service: pending.service
            )
            return "Message sent to \(pending.recipient)."
        } catch {
            return "Failed to send iMessage: \(error.localizedDescription)"
        }
    }
}

struct PendingShellCommand: Identifiable, Equatable, Sendable {
    let id: UUID
    let command: String
    let runInBackground: Bool
    let conversationID: UUID?
}

enum ModelType: String, CaseIterable, Identifiable, Codable {
    case codex = "Codex (ChatGPT Subscription)"
    case openai = "OpenAI (ChatGPT)"

    var id: String { self.rawValue }

    /// Maps persisted raw values, including removed backends, to a supported model.
    static func resolved(fromStored rawValue: String?) -> ModelType {
        guard let rawValue else { return .openai }
        if let model = ModelType(rawValue: rawValue) {
            return model
        }
        return .openai
    }

    static func preferredForSpecializedAgents() -> ModelType {
        let openaiKey = KeychainHelper.retrieve(key: "openai_api_key") ?? ""
        if !openaiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .openai
        }
        return .openai
    }
}
