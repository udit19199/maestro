//
//  WorkspaceManager.swift
//  zoro
//
//  Created by Udit Agarwal on 19/06/26.
//

// Foundation is Apple's core library
// containing essential non-UI data types, networking, and system APIs.
import Foundation
import Combine
import FoundationModels

// 'ObservableObject' is a protocol that allows SwiftUI to listen to this
// object for data changes and automatically redraw the user interface.
@MainActor
class WorkspaceManager: ObservableObject {
    
    // The "Singleton" pattern: creates a single shared instance of this manager.
    // 'static let' makes it globally accessible via `WorkspaceManager.shared`.
    static let shared = WorkspaceManager()
    
    // '@Published' tells SwiftUI: "If this variable changes, alert any views
    // that are listening so they can update themselves."
    // 'URL?' means this is an "Optional" URL. It can hold a folder path OR be 'nil' (empty).
    @Published var workspaceURL: URL? = nil
    
    @Published var selectedModelType: ModelType = .system
    @Published var pendingCalendarProposals: [PlannerEventProposal] = []
    @Published var pendingMailSend: PendingMailSendRequest?
    @Published var activeClarificationQuestion: String? = nil

    var clarifyContinuation: CheckedContinuation<String, Never>? = nil
    var activeConversationID: UUID?
    var activeAgentType: AgentType?
    var isIMessageContext = false

    var currentExecutionContext: AgentExecutionContext = .local
    var iMessageRequester: String?

    func invalidateSessionsForConfigChange() {
        AgentRunner.shared.invalidateAllSessions()
    }

    func finishRemoteExecution() {
        currentExecutionContext = .local
        iMessageRequester = nil
    }

    func toolPermissionError(for toolName: String) -> String? {
        guard SecurityPolicy.isToolPermitted(toolName, context: currentExecutionContext) else {
            return "Error: Tool '\(toolName)' is not permitted in \(SecurityPolicy.contextDescription(currentExecutionContext))."
        }
        return nil
    }

    /// Clears ephemeral agent state and invalidates LLM sessions (messages persist in ConversationStore).
    func resetSession() {
        AgentRunner.shared.invalidateAllSessions()
        activeTodos = []
        clearResearchSteps()
        pendingCalendarProposals = []
        pendingMailSend = nil
        activeConversationID = nil
        activeAgentType = nil
        isIMessageContext = false
        currentExecutionContext = .local
        iMessageRequester = nil
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
        var status: String // "in_progress", "completed", "failed"
    }
    
    @Published var researchSteps: [ResearchStep] = []
    
    func addResearchStep(_ title: String) -> UUID {
        let id = UUID()
        DispatchQueue.main.async {
            self.researchSteps.append(ResearchStep(id: id, title: title, status: "in_progress"))
        }
        return id
    }
    
    func completeResearchStep(id: UUID) {
        DispatchQueue.main.async {
            if let index = self.researchSteps.firstIndex(where: { $0.id == id }) {
                self.researchSteps[index].status = "completed"
            }
        }
    }
    
    func failResearchStep(id: UUID) {
        DispatchQueue.main.async {
            if let index = self.researchSteps.firstIndex(where: { $0.id == id }) {
                self.researchSteps[index].status = "failed"
            }
        }
    }
    
    func clearResearchSteps() {
        DispatchQueue.main.async {
            self.researchSteps = []
        }
    }
    
    func updateTodos(_ newTodos: [TodoItem], merge: Bool) -> [TodoItem] {
        DispatchQueue.main.async {
            if !merge {
                self.activeTodos = newTodos
            } else {
                var current = self.activeTodos
                for item in newTodos {
                    if let idx = current.firstIndex(where: { $0.id == item.id }) {
                        current[idx].content = item.content
                        current[idx].status = item.status
                    } else {
                        current.append(item)
                    }
                }
                self.activeTodos = current
            }
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
        
        DispatchQueue.main.async {
            self.activeProcesses[taskId] = running
        }
        
        return "Command started in the background. Task ID: \(taskId)\nUse 'get_process_status' with this ID to inspect logs."
    }
    
    // 'async throws' means this function runs in the background (asynchronously)
    // and can throw errors if something fails (like permission errors).
    func pruneTerminatedProcesses() {
        activeProcesses = activeProcesses.filter { $0.value.isRunning }
    }

    func runCommand(_ command: String) async throws -> String {
        
        // 'guard let ... else' is Swift's way of unwrapping an Optional.
        // It says: "If workspaceURL has a value, assign it to a temporary variable.
        // If it is nil, immediately exit the function with an error message."
        guard let workspaceURL = workspaceURL else {
            return "Error: No workspace directory selected."
        }
        
        let process = Process()
        
        // 'Pipe' is used to capture output data stream from the process.
        let pipe = Pipe()
        
        // Redirect the command's standard output and error logs into our pipe.
        process.standardOutput = pipe
        process.standardError = pipe
        
        // Tell the process to execute zsh (the Mac terminal shell) with the "-c" flag.
        // "-c" tells zsh to read the next argument string as a command to run.
        process.arguments = ["-c", command]
        process.launchPath = "/bin/zsh"
        
        // Tell the zsh shell where to look. We set its working directory to
        // the active folder selected by the user.
        process.currentDirectoryURL = workspaceURL
        
        // 'try' runs a command that could fail. If it fails, the function exits
        // and throws the error. 'run()' launches the shell command.
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
}

enum ModelType: String, CaseIterable, Identifiable, Codable {
    case system = "On-Device (Apple Intelligence)"
    case pcc = "Private Cloud Compute"
    case codex = "Codex (ChatGPT Subscription)"
    case claude = "Claude (Anthropic)"
    case gemini = "Gemini (Google)"
    case openai = "OpenAI (ChatGPT)"

    var id: String { self.rawValue }

    static func preferredForSpecializedAgents() -> ModelType {
        let openaiKey = KeychainHelper.retrieve(key: "openai_api_key") ?? ""
        if !openaiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .openai
        }
        return .system
    }
}

