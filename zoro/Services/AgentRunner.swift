//
//  AgentRunner.swift
//  zoro
//

import Foundation
import Combine
import FoundationModels

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
        conversationStore: ConversationStore? = nil,
        workspace: WorkspaceManager? = nil,
        onComplete: ((String) -> Void)? = nil
    ) async {
        // Default args cannot reference MainActor `.shared` (evaluated nonisolated).
        let conversationStore = conversationStore ?? .shared
        let workspace = workspace ?? .shared

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let conversation = conversationStore.conversation(id: conversationID) else { return }

        workspace.clearResearchSteps()
        // Do not clear pending mail/iMessage/shell/calendar — those wait for user confirm.
        workspace.activeConversationID = conversationID
        workspace.activeAgentType = conversation.agentType

        switch conversation.executionContext() {
        case .failure(let securityError):
            let message = securityError.localizedDescription
            conversationStore.appendMessage(to: conversationID, message: StoredMessage(role: .user, content: trimmed))
            conversationStore.appendMessage(
                to: conversationID,
                message: StoredMessage(role: .assistant, content: message)
            )
            clearActiveContext(workspace: workspace)
            onComplete?(message)
            return
        case .success:
            break
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

        MailReadAuditor.resetPromptState()
        MailManager.shared.clearSessionReads()

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
                conversation: conversation,
                modelType: modelType
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

            let auditedContent = MailReadAuditor.auditAssistantResponse(finalContent, userPrompt: trimmed)
            if auditedContent != finalContent {
                finalContent = auditedContent
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
    }

    private func resolvedModelType(for agentType: AgentType, userSelected: ModelType) -> ModelType {
        switch agentType {
        case .default:
            return userSelected
        case .research, .planner, .teach:
            return ModelType.preferredForSpecializedAgents()
        }
    }

    private func getOrCreateSession(
        conversation: Conversation,
        modelType: ModelType
    ) throws -> LanguageModelSession {
        let conversationID = conversation.id
        if let session = sessions[conversationID] {
            return session
        }

        let executionContext: AgentExecutionContext
        switch conversation.executionContext() {
        case .failure(let securityError):
            throw modelKeyError(securityError.localizedDescription)
        case .success(let ctx):
            executionContext = ctx
        }

        var instructions = AgentPrompts.systemInstructions(
            for: conversation.agentType,
            profileContext: ProfileStore.shared.profileContextForPrompt()
        )

        instructions += """


        Human-in-the-loop (enforced by the app, not optional):
        - Email, iMessage, shell commands, and calendar creates are staged for user confirmation. Never claim they were sent/run/created until the user confirms in the UI.
        - Do not invent that a message was delivered.
        """

        if conversation.agentType == .teach, let metadata = conversation.tutoringMetadata {
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

        if conversation.agentType == .default, let mailInstructions = MailManager.shared.contextualInstructions() {
            instructions += "\n\n" + mailInstructions
        }

        let toolSet = ToolFactory.tools(for: conversation.agentType, executionContext: executionContext)

        let newSession: LanguageModelSession
        let openaiApiKey = KeychainHelper.retrieve(key: "openai_api_key") ?? ""

        switch modelType {
        case .openai:
            guard !openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw modelKeyError("OpenAI API Key is missing. Please enter your API Key in Settings.")
            }
            newSession = LanguageModelSession(
                model: OpenAILanguageModel(modelName: "gpt-4o-mini", apiKey: openaiApiKey),
                tools: toolSet,
                instructions: instructions
            )
        case .codex:
            guard KeychainHelper.retrieve(key: "codex_refresh_token") != nil else {
                throw modelKeyError("Codex is not connected. Sign in with your ChatGPT account in Settings.")
            }
            let modelName = CodexAuthSupport.normalizedModelName(
                UserDefaults.standard.string(forKey: "codex_model_name") ?? "gpt-5-codex"
            )
            newSession = LanguageModelSession(
                model: CodexLanguageModel(modelName: modelName),
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
        case .openai:
            let key = KeychainHelper.retrieve(key: "openai_api_key") ?? ""
            if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Please enter your OpenAI API key in Settings."
            }
        case .codex:
            if KeychainHelper.retrieve(key: "codex_refresh_token") == nil {
                return "Sign in with ChatGPT or import from Codex CLI in Settings."
            }
        }
        return nil
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
            let openaiApiKey = KeychainHelper.retrieve(key: "openai_api_key") ?? ""

            switch modelType {
            case .openai:
                tempSession = LanguageModelSession(
                    model: OpenAILanguageModel(modelName: "gpt-4o-mini", apiKey: openaiApiKey)
                )
            case .codex:
                let modelName = CodexAuthSupport.normalizedModelName(
                    UserDefaults.standard.string(forKey: "codex_model_name") ?? "gpt-5-codex"
                )
                tempSession = LanguageModelSession(model: CodexLanguageModel(modelName: modelName))
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
