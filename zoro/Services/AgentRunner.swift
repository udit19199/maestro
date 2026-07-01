//
//  AgentRunner.swift
//  zoro
//

import Foundation
import Combine
import FoundationModels
import ClaudeForFoundationModels

@MainActor
final class AgentRunner: ObservableObject {
    static let shared = AgentRunner()

    @Published private(set) var runningConversationIDs: Set<UUID> = []

    private var sessions: [UUID: LanguageModelSession] = [:]
    private var conversationSummaries: [UUID: String] = [:]

    private init() {}

    func isRunning(conversationID: UUID) -> Bool {
        runningConversationIDs.contains(conversationID)
    }

    func invalidateAllSessions() {
        sessions.removeAll()
        conversationSummaries.removeAll()
    }

    func invalidateSession(for conversationID: UUID) {
        sessions.removeValue(forKey: conversationID)
        conversationSummaries.removeValue(forKey: conversationID)
    }

    func sendMessage(
        conversationID: UUID,
        text: String,
        conversationStore: ConversationStore = .shared,
        workspace: WorkspaceManager = .shared,
        onComplete: ((String) -> Void)? = nil
    ) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let conversation = conversationStore.conversation(id: conversationID) else { return }

        workspace.clearResearchSteps()
        workspace.pendingCalendarProposals = []
        workspace.activeConversationID = conversationID
        workspace.activeAgentType = conversation.agentType
        if conversation.source == .imessage {
            workspace.isIMessageContext = true
            workspace.currentExecutionContext = .iMessage(requester: workspace.iMessageRequester ?? "")
        } else {
            workspace.isIMessageContext = false
            workspace.currentExecutionContext = .local
        }

        if let continuation = workspace.clarifyContinuation {
            conversationStore.appendMessage(to: conversationID, message: StoredMessage(role: .user, content: trimmed))
            conversationStore.appendMessage(
                to: conversationID,
                message: StoredMessage(role: .assistant, content: "Thinking...")
            )
            workspace.activeClarificationQuestion = nil
            workspace.clarifyContinuation = nil
            runningConversationIDs.insert(conversationID)
            continuation.resume(returning: trimmed)
            return
        }

        runningConversationIDs.insert(conversationID)
        conversationStore.appendMessage(to: conversationID, message: StoredMessage(role: .user, content: trimmed))
        conversationStore.appendMessage(
            to: conversationID,
            message: StoredMessage(role: .assistant, content: "Thinking...")
        )

        let modelType = resolvedModelType(for: conversation.agentType, userSelected: workspace.selectedModelType)

        if let availabilityError = await checkModelAvailability(modelType: modelType) {
            conversationStore.updateLastMessageContent(conversationID: conversationID, content: availabilityError)
            clearActiveContext(workspace: workspace)
            runningConversationIDs.remove(conversationID)
            onComplete?(availabilityError)
            return
        }

        do {
            let activeSession = try getOrCreateSession(
                conversationID: conversationID,
                agentType: conversation.agentType,
                modelType: modelType,
                tutoringMetadata: conversation.tutoringMetadata
            )

            var promptText = trimmed
            if let summary = conversationSummaries[conversationID] {
                promptText = """
                [System Note: The conversation context exceeded the model limit and was compressed. Here is a summary of the prior turns:
                \(summary)]

                \(trimmed)
                """
            }

            let stream = activeSession.streamResponse(to: promptText)
            var finalContent = ""

            for try await partialContent in stream {
                finalContent = partialContent.content
                conversationStore.updateLastMessageContent(conversationID: conversationID, content: finalContent)
            }

            conversationSummaries.removeValue(forKey: conversationID)
            runningConversationIDs.remove(conversationID)
            clearActiveContext(workspace: workspace)

            if let updatedConversation = conversationStore.conversation(id: conversationID) {
                MemoryExtractor.processConversation(updatedConversation)
            }

            onComplete?(finalContent)
        } catch {
            let errMsg = error.localizedDescription
            if errMsg.lowercased().contains("context size")
                || errMsg.lowercased().contains("transcript exceeded")
                || errMsg.lowercased().contains("context limit") {
                let summary = await compressConversationHistory(
                    conversationID: conversationID,
                    conversationStore: conversationStore,
                    modelType: modelType
                )
                sessions.removeValue(forKey: conversationID)
                conversationSummaries[conversationID] = summary
                conversationStore.appendMessage(
                    to: conversationID,
                    message: StoredMessage(
                        role: .assistant,
                        content: """
                        The conversation history exceeded the model's context size. It has been compressed. Previous context summary:

                        "\(summary)"

                        Please try your request again.
                        """
                    )
                )
            } else {
                conversationStore.updateLastMessageContent(
                    conversationID: conversationID,
                    content: """
                    Error: \(errMsg)

                    Tip: Open Settings (⌘,) and configure a model backend if Apple Intelligence is unavailable.
                    """
                )
            }
            clearActiveContext(workspace: workspace)
            runningConversationIDs.remove(conversationID)
            onComplete?(errMsg)
        }
    }

    private func clearActiveContext(workspace: WorkspaceManager) {
        workspace.activeConversationID = nil
        workspace.activeAgentType = nil
        workspace.isIMessageContext = false
        workspace.currentExecutionContext = .local
        workspace.iMessageRequester = nil
    }

    private func resolvedModelType(for agentType: AgentType, userSelected: ModelType) -> ModelType {
        switch agentType {
        case .default:
            return .system
        case .research, .planner, .teach:
            return ModelType.preferredForSpecializedAgents()
        }
    }

    private func tools(for agentType: AgentType) -> [any Tool] {
        switch agentType {
        case .default:
            return [
                CommandLineTool(),
                ProcessStatusTool(),
                ListDirectoryTool(),
                ReadFileTool(),
                WriteFileTool(),
                PatchTool(),
                SearchFilesTool(),
                CurrentTimeTool(),
                ClarifyTool(),
                TodoTool(),
                EventKitTool(),
                AppleNotesTool(),
                TavilySearchTool(),
                IMessageTool(),
                ProfileMemoryTool()
            ]
        case .research:
            return [
                TavilySearchTool(),
                AppleNotesTool(),
                CurrentTimeTool(),
                ClarifyTool(),
                TodoTool(),
                ProfileMemoryTool(),
                ReadFileTool(),
                SearchFilesTool()
            ]
        case .planner:
            return [
                EventKitTool(),
                ProposeCalendarEventsTool(),
                CurrentTimeTool(),
                ClarifyTool(),
                TodoTool(),
                ProfileMemoryTool(),
                AppleNotesTool()
            ]
        case .teach:
            return [
                TeachProgressTool(),
                ProfileMemoryTool(),
                ClarifyTool(),
                AppleNotesTool(),
                CurrentTimeTool()
            ]
        }
    }

    private func getOrCreateSession(
        conversationID: UUID,
        agentType: AgentType,
        modelType: ModelType,
        tutoringMetadata: TutoringMetadata?
    ) throws -> LanguageModelSession {
        if let session = sessions[conversationID] {
            return session
        }

        var instructions = AgentPrompts.systemInstructions(
            for: agentType,
            profileContext: ProfileStore.shared.profileContextForPrompt()
        )

        if agentType == .teach, let metadata = tutoringMetadata {
            var tutoringContext: [String] = []
            if let topic = metadata.curriculumTopic { tutoringContext.append("Topic: \(topic)") }
            if let module = metadata.currentModule { tutoringContext.append("Current module: \(module)") }
            if let completed = metadata.completedModules, !completed.isEmpty {
                tutoringContext.append("Completed: \(completed.joined(separator: ", "))")
            }
            if let last = metadata.lastLessonSummary { tutoringContext.append("Last lesson: \(last)") }
            if let next = metadata.nextExercise { tutoringContext.append("Next exercise: \(next)") }
            if !tutoringContext.isEmpty {
                instructions += "\n\nTutoring state for this thread:\n" + tutoringContext.joined(separator: "\n")
            }
        }

        let toolSet = tools(for: agentType)

        let newSession: LanguageModelSession
        let anthropicApiKey = KeychainHelper.retrieve(key: "anthropic_api_key") ?? ""
        let geminiApiKey = KeychainHelper.retrieve(key: "gemini_api_key") ?? ""
        let openaiApiKey = KeychainHelper.retrieve(key: "openai_api_key") ?? ""

        switch modelType {
        case .system:
            newSession = LanguageModelSession(
                model: SystemLanguageModel.default,
                tools: toolSet,
                instructions: instructions
            )
        case .pcc:
            newSession = LanguageModelSession(
                model: PrivateCloudComputeLanguageModel(),
                tools: toolSet,
                instructions: instructions
            )
        case .claude:
            guard !anthropicApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw modelKeyError("Anthropic API Key is missing. Please enter your API Key in Settings.")
            }
            newSession = LanguageModelSession(
                model: ClaudeLanguageModel(name: .sonnet4_6, auth: .apiKey(anthropicApiKey)),
                tools: toolSet,
                instructions: instructions
            )
        case .gemini:
            guard !geminiApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw modelKeyError("Gemini API Key is missing. Please enter your API Key in Settings.")
            }
            newSession = LanguageModelSession(
                model: GeminiLanguageModel(modelName: "gemini-2.5-flash", apiKey: geminiApiKey),
                tools: toolSet,
                instructions: instructions
            )
        case .openai:
            guard !openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw modelKeyError("OpenAI API Key is missing. Please enter your API Key in Settings.")
            }
            newSession = LanguageModelSession(
                model: OpenAILanguageModel(modelName: "gpt-4o-mini", apiKey: openaiApiKey),
                tools: toolSet,
                instructions: instructions
            )
        }

        sessions[conversationID] = newSession
        return newSession
    }

    private func modelKeyError(_ message: String) -> NSError {
        NSError(domain: "ZoroError", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func checkModelAvailability(modelType: ModelType) async -> String? {
        switch modelType {
        case .system:
            let status = SystemLanguageModel.default.availability
            if case .unavailable(let reason) = status {
                return """
                On-Device Apple Intelligence model is not ready yet.

                Reason: \(reasonDescription(for: reason))

                Tip: Open Settings (⌘,) and configure OpenAI, Claude, or Gemini to test Zoro's tools immediately.
                """
            }
        case .pcc:
            let status = PrivateCloudComputeLanguageModel().availability
            if case .unavailable(let reason) = status {
                return """
                Private Cloud Compute is not available.

                Reason: \(reason)

                Tip: Open Settings and switch to another backend.
                """
            }
        case .claude:
            let key = KeychainHelper.retrieve(key: "anthropic_api_key") ?? ""
            if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Please enter your Anthropic API key in Settings."
            }
        case .gemini:
            let key = KeychainHelper.retrieve(key: "gemini_api_key") ?? ""
            if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Please enter your Gemini API key in Settings."
            }
        case .openai:
            let key = KeychainHelper.retrieve(key: "openai_api_key") ?? ""
            if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Please enter your OpenAI API key in Settings."
            }
        }
        return nil
    }

    private func reasonDescription(for reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .modelNotReady:
            return "Model assets are downloading/preparing. Please stay connected to Wi-Fi and power."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is disabled. Enable it under Settings > Apple Intelligence & Siri."
        case .deviceNotEligible:
            return "This Mac hardware does not support Apple Intelligence."
        @unknown default:
            return "Unknown unavailability reason: \(String(describing: reason))"
        }
    }

    private func compressConversationHistory(
        conversationID: UUID,
        conversationStore: ConversationStore,
        modelType: ModelType
    ) async -> String {
        guard let conversation = conversationStore.conversation(id: conversationID) else {
            return "No prior context."
        }

        let chatText = conversation.messages
            .map { "\($0.role.rawValue): \($0.content)" }
            .joined(separator: "\n")

        do {
            let tempSession: LanguageModelSession
            let anthropicApiKey = KeychainHelper.retrieve(key: "anthropic_api_key") ?? ""
            let geminiApiKey = KeychainHelper.retrieve(key: "gemini_api_key") ?? ""
            let openaiApiKey = KeychainHelper.retrieve(key: "openai_api_key") ?? ""

            switch modelType {
            case .system:
                tempSession = LanguageModelSession(model: SystemLanguageModel.default)
            case .pcc:
                tempSession = LanguageModelSession(model: PrivateCloudComputeLanguageModel())
            case .claude:
                tempSession = LanguageModelSession(
                    model: ClaudeLanguageModel(name: .sonnet4_6, auth: .apiKey(anthropicApiKey))
                )
            case .gemini:
                tempSession = LanguageModelSession(
                    model: GeminiLanguageModel(modelName: "gemini-2.5-flash", apiKey: geminiApiKey)
                )
            case .openai:
                tempSession = LanguageModelSession(
                    model: OpenAILanguageModel(modelName: "gpt-4o-mini", apiKey: openaiApiKey)
                )
            }

            let prompt = """
            Please write a highly concise summary (under 100 words) of the conversation so far, focusing on what was accomplished and what context is needed to continue:

            \(chatText)
            """
            let stream = tempSession.streamResponse(to: prompt)
            var summaryContent = ""
            for try await chunk in stream {
                summaryContent += chunk.content
            }
            if !summaryContent.isEmpty {
                return summaryContent
            }
        } catch {
            // Fallback below
        }

        let lastMessages = conversation.messages.suffix(4)
        let summaryText = lastMessages.map { "\($0.role.rawValue): \($0.content)" }.joined(separator: "\n")
        return "Last turns of conversation:\n\(summaryText)"
    }
}
