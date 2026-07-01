//
//  CodexLanguageModel.swift
//  zoro
//
//  OpenAI Codex backend via ChatGPT subscription (Responses API).
//

import Foundation
import FoundationModels

// MARK: - Codex Language Model

public struct CodexLanguageModel: Sendable {
    public let modelName: String
    public let timeout: TimeInterval

    public init(modelName: String = "gpt-5-codex", timeout: TimeInterval = 120) {
        self.modelName = CodexAuthSupport.normalizedModelName(modelName)
        self.timeout = timeout
    }
}

extension CodexLanguageModel: LanguageModel {
    public typealias Executor = CodexExecutor

    public var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities(capabilities: [.toolCalling])
    }

    public var executorConfiguration: CodexExecutor.Configuration {
        .init(modelName: modelName, timeout: timeout)
    }
}

// MARK: - Codex Executor

public struct CodexExecutor: LanguageModelExecutor {
    public typealias Model = CodexLanguageModel

    public struct Configuration: Hashable, Sendable {
        public let modelName: String
        public let timeout: TimeInterval

        public init(modelName: String, timeout: TimeInterval) {
            self.modelName = CodexAuthSupport.normalizedModelName(modelName)
            self.timeout = timeout
        }
    }

    private let configuration: Configuration

    public init(configuration: Configuration) throws {
        self.configuration = configuration
    }

    @MainActor
    public func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: CodexLanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        var credentials = try await CodexAuthManager.shared.getValidCredentials()
        var hasRetriedAfterUnauthorized = false

        while true {
            do {
                try await streamResponse(
                    request: request,
                    credentials: credentials,
                    responseEntryID: UUID().uuidString,
                    toolCallsEntryID: UUID().uuidString,
                    streamingInto: channel
                )
                return
            } catch let error as NSError where error.domain == "CodexExecutor" && error.code == 401 {
                guard !hasRetriedAfterUnauthorized else { throw error }
                hasRetriedAfterUnauthorized = true
                credentials = try await CodexAuthManager.shared.getValidCredentials(forceRefresh: true)
            }
        }
    }

    @MainActor
    private func streamResponse(
        request: LanguageModelExecutorGenerationRequest,
        credentials: CodexCredentials,
        responseEntryID: String,
        toolCallsEntryID: String,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        var instructions: String?
        var inputItems: [CodexJSONValue] = []

        for entry in request.transcript {
            switch entry {
            case .instructions(let instructionEntry):
                instructions = text(from: instructionEntry.segments)

            case .prompt(let prompt):
                let textContent = text(from: prompt.segments)
                inputItems.append(.object([
                    "type": .string("message"),
                    "role": .string("user"),
                    "content": .array([
                        .object([
                            "type": .string("input_text"),
                            "text": .string(textContent)
                        ])
                    ])
                ]))

            case .toolCalls(let toolCalls):
                for call in toolCalls {
                    inputItems.append(.object([
                        "type": .string("function_call"),
                        "call_id": .string(call.id),
                        "name": .string(call.toolName),
                        "arguments": .string(call.arguments.jsonString)
                    ]))
                }

            case .toolOutput(let toolOutput):
                let resultText = text(from: toolOutput.segments)
                inputItems.append(.object([
                    "type": .string("function_call_output"),
                    "call_id": .string(toolOutput.id),
                    "output": .string(resultText)
                ]))

            case .response(let response):
                let textContent = text(from: response.segments)
                inputItems.append(.object([
                    "type": .string("message"),
                    "role": .string("assistant"),
                    "content": .array([
                        .object([
                            "type": .string("output_text"),
                            "text": .string(textContent)
                        ])
                    ])
                ]))

            case .reasoning:
                break

            @unknown default:
                break
            }
        }

        var tools: [CodexJSONValue] = []
        for toolDef in request.enabledToolDefinitions {
            let paramData = try? JSONEncoder().encode(toolDef.parameters)
            let parameters = paramData.flatMap { try? JSONDecoder().decode(CodexJSONValue.self, from: $0) }
            tools.append(.object([
                "type": .string("function"),
                "name": .string(toolDef.name),
                "description": .string(toolDef.description),
                "parameters": parameters ?? .object([:])
            ]))
        }

        let payload = CodexRequestSupport.buildRequestPayload(
            modelName: configuration.modelName,
            instructions: instructions,
            inputItems: inputItems,
            tools: tools,
            temperature: request.generationOptions.temperature
        )

        guard let url = URL(string: CodexRequestSupport.responsesEndpoint) else {
            throw NSError(domain: "CodexExecutor", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid Codex endpoint URL."])
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        if !credentials.accountID.isEmpty {
            urlRequest.setValue(credentials.accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        }
        urlRequest.timeoutInterval = configuration.timeout
        urlRequest.httpBody = try JSONEncoder().encode(payload)

        let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "CodexExecutor", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])
        }

        if httpResponse.statusCode == 401 {
            throw NSError(
                domain: "CodexExecutor",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "Codex session expired. Try signing in again in Settings."]
            )
        }

        if httpResponse.statusCode != 200 {
            var errorBody = ""
            for try await byte in bytes {
                if let char = String(bytes: [byte], encoding: .utf8) {
                    errorBody += char
                }
            }
            throw NSError(
                domain: "CodexExecutor",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Codex HTTP error \(httpResponse.statusCode): \(CodexAuthSupport.sanitizedErrorDetail(errorBody))"]
            )
        }

        var parser = CodexStreamParser()
        var startedToolCalls: Set<String> = []
        var toolNamesByID: [String: String] = [:]
        var line = ""

        for try await byte in bytes {
            if byte == 10 {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("data: ") {
                    let jsonString = String(trimmed.dropFirst(6))
                    if jsonString == "[DONE]" { break }

                    do {
                        let actions = try parser.consume(eventJSON: jsonString)
                        for action in actions {
                            try await apply(
                                action,
                                responseEntryID: responseEntryID,
                                toolCallsEntryID: toolCallsEntryID,
                                startedToolCalls: &startedToolCalls,
                                toolNamesByID: &toolNamesByID,
                                channel: channel
                            )
                        }
                    } catch let failure as CodexStreamFailure {
                        throw NSError(
                            domain: "CodexExecutor",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Codex generation failed: \(failure.message)"]
                        )
                    }
                }
                line = ""
            } else if let char = String(bytes: [byte], encoding: .utf8) {
                line += char
            }
        }
    }

    @MainActor
    private func apply(
        _ action: CodexStreamAction,
        responseEntryID: String,
        toolCallsEntryID: String,
        startedToolCalls: inout Set<String>,
        toolNamesByID: inout [String: String],
        channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        switch action {
        case .appendText(let delta):
            await channel.send(.response(
                entryID: responseEntryID,
                action: .appendText(delta, tokenCount: 1)
            ))

        case .startToolCall(let id, let name):
            toolNamesByID[id] = name
            guard !startedToolCalls.contains(id) else { return }
            startedToolCalls.insert(id)
            await channel.send(.toolCalls(
                entryID: toolCallsEntryID,
                action: .toolCall(id: id, name: name, action: .appendArguments("", tokenCount: 0))
            ))

        case .appendToolArguments(let id, let delta):
            let name = toolNamesByID[id] ?? ""
            await channel.send(.toolCalls(
                entryID: toolCallsEntryID,
                action: .toolCall(id: id, name: name, action: .appendArguments(delta, tokenCount: 1))
            ))

        case .completeToolCall(let id, let name, let arguments):
            toolNamesByID[id] = name
            if !startedToolCalls.contains(id) {
                startedToolCalls.insert(id)
                await channel.send(.toolCalls(
                    entryID: toolCallsEntryID,
                    action: .toolCall(id: id, name: name, action: .appendArguments("", tokenCount: 0))
                ))
            }
            await channel.send(.toolCalls(
                entryID: toolCallsEntryID,
                action: .toolCall(id: id, name: name, action: .appendArguments(arguments, tokenCount: 1))
            ))

        case .updateUsage(let inputTokens, let outputTokens):
            await channel.send(.response(
                entryID: responseEntryID,
                action: .updateUsage(
                    input: .init(totalTokenCount: inputTokens, cachedTokenCount: 0),
                    output: .init(totalTokenCount: outputTokens, reasoningTokenCount: 0)
                )
            ))

        case .failed(let message):
            throw NSError(domain: "CodexExecutor", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func text(from segments: [Transcript.Segment]) -> String {
        segments.compactMap { segment in
            switch segment {
            case .text(let textSegment):
                return textSegment.content
            case .structure(let structuredSegment):
                return structuredSegment.content.jsonString
            default:
                return nil
            }
        }.joined(separator: "\n")
    }
}
