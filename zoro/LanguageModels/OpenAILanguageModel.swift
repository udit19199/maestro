//
//  OpenAILanguageModel.swift
//  zoro
//

import Foundation
import FoundationModels

public struct OpenAILanguageModel: Sendable {
    public let modelName: String
    public let apiKey: String
    public let timeout: TimeInterval

    public init(
        modelName: String = "gpt-4o-mini",
        apiKey: String,
        timeout: TimeInterval = 60
    ) {
        self.modelName = modelName
        self.apiKey = apiKey
        self.timeout = timeout
    }
}

extension OpenAILanguageModel: LanguageModel {
    public typealias Executor = OpenAIExecutor

    public var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities(capabilities: [.toolCalling])
    }

    public var executorConfiguration: OpenAIExecutor.Configuration {
        .init(modelName: modelName, apiKey: apiKey, timeout: timeout)
    }
}

public struct OpenAIExecutor: LanguageModelExecutor {
    public typealias Model = OpenAILanguageModel

    public struct Configuration: Hashable, Sendable {
        public let modelName: String
        public let apiKey: String
        public let timeout: TimeInterval

        public init(modelName: String, apiKey: String, timeout: TimeInterval) {
            self.modelName = modelName
            self.apiKey = apiKey
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
        model: OpenAILanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        let responseEntryID = UUID().uuidString
        let toolCallsEntryID = UUID().uuidString

        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw NSError(domain: "OpenAIExecutor", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid OpenAI API endpoint URL"])
        }

        var messages: [OpenAIRequest.Message] = []
        for entry in request.transcript {
            switch entry {
            case .instructions(let instructions):
                let textContent = text(from: instructions.segments)
                messages.append(.init(role: "system", content: textContent))

            case .prompt(let prompt):
                let textContent = text(from: prompt.segments)
                messages.append(.init(role: "user", content: textContent))

            case .toolCalls(let toolCalls):
                for call in toolCalls {
                    let argsData = call.arguments.jsonString.data(using: .utf8) ?? Data()
                    let argsString = String(data: argsData, encoding: .utf8) ?? "{}"
                    messages.append(.init(
                        role: "assistant",
                        content: nil,
                        toolCalls: [.init(id: call.id, type: "function", function: .init(name: call.toolName, arguments: argsString))]
                    ))
                }

            case .toolOutput(let toolOutput):
                let resultText = text(from: toolOutput.segments)
                messages.append(.init(role: "tool", content: resultText, toolCallID: toolOutput.id))

            case .response(let response):
                let textContent = text(from: response.segments)
                messages.append(.init(role: "assistant", content: textContent))

            case .reasoning:
                break

            @unknown default:
                break
            }
        }

        var tools: [OpenAIRequest.Tool]? = nil
        if !request.enabledToolDefinitions.isEmpty {
            tools = request.enabledToolDefinitions.map { toolDef in
                let paramData = (try? JSONEncoder().encode(toolDef.parameters)) ?? Data()
                let paramObject = (try? JSONSerialization.jsonObject(with: paramData)) as? [String: Any] ?? [:]
                return OpenAIRequest.Tool(
                    type: "function",
                    function: .init(
                        name: toolDef.name,
                        description: toolDef.description,
                        parameters: paramObject.mapValues { AnyEncodableValue($0) }
                    )
                )
            }
        }

        let openAIRequest = OpenAIRequest(
            model: configuration.modelName,
            messages: messages,
            tools: tools,
            stream: true,
            temperature: request.generationOptions.temperature,
            maxTokens: request.generationOptions.maximumResponseTokens
        )

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.timeoutInterval = configuration.timeout
        urlRequest.httpBody = try JSONEncoder().encode(openAIRequest)

        let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "OpenAIExecutor", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])
        }

        if httpResponse.statusCode != 200 {
            var errorBody = ""
            for try await byte in bytes {
                if let char = String(bytes: [byte], encoding: .utf8) {
                    errorBody += char
                }
            }
            throw NSError(domain: "OpenAIExecutor", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP error \(httpResponse.statusCode): \(errorBody)"])
        }

        var line = ""
        var toolCallBuffers: [Int: (id: String, name: String, arguments: String)] = [:]

        for try await byte in bytes {
            if byte == 10 {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("data: ") {
                    let payload = String(trimmed.dropFirst(6))
                    if payload == "[DONE]" { break }
                    guard let data = payload.data(using: .utf8),
                          let chunk = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: data),
                          let choice = chunk.choices?.first else {
                        line = ""
                        continue
                    }

                    if let delta = choice.delta?.content, !delta.isEmpty {
                        await channel.send(.response(
                            entryID: responseEntryID,
                            action: .appendText(delta, tokenCount: 1)
                        ))
                    }

                    if let toolCalls = choice.delta?.toolCalls {
                        for toolCall in toolCalls {
                            let index = toolCall.index ?? 0
                            var buffer = toolCallBuffers[index] ?? (id: toolCall.id ?? "call_\(index)", name: "", arguments: "")
                            if let id = toolCall.id { buffer.id = id }
                            if let name = toolCall.function?.name { buffer.name = name }
                            if let args = toolCall.function?.arguments { buffer.arguments += args }
                            toolCallBuffers[index] = buffer
                        }
                    }

                    if choice.finishReason == "tool_calls" || choice.finishReason == "stop" {
                        for (_, buffer) in toolCallBuffers.sorted(by: { $0.key < $1.key }) where !buffer.name.isEmpty {
                            await channel.send(.toolCalls(
                                entryID: toolCallsEntryID,
                                action: .toolCall(id: buffer.id, name: buffer.name, action: .appendArguments("", tokenCount: 0))
                            ))
                            await channel.send(.toolCalls(
                                entryID: toolCallsEntryID,
                                action: .toolCall(id: buffer.id, name: buffer.name, action: .appendArguments(buffer.arguments, tokenCount: 1))
                            ))
                        }
                    }
                }
                line = ""
            } else if let char = String(bytes: [byte], encoding: .utf8) {
                line += char
            }
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

private struct OpenAIRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String?
        var toolCalls: [ToolCall]?
        var toolCallID: String?

        enum CodingKeys: String, CodingKey {
            case role, content
            case toolCalls = "tool_calls"
            case toolCallID = "tool_call_id"
        }

        init(role: String, content: String?, toolCalls: [ToolCall]? = nil, toolCallID: String? = nil) {
            self.role = role
            self.content = content
            self.toolCalls = toolCalls
            self.toolCallID = toolCallID
        }
    }

    struct ToolCall: Encodable {
        let id: String
        let type: String
        let function: FunctionCall
    }

    struct FunctionCall: Encodable {
        let name: String
        let arguments: String
    }

    struct Tool: Encodable {
        let type: String
        let function: FunctionDefinition
    }

    struct FunctionDefinition: Encodable {
        let name: String
        let description: String
        let parameters: [String: AnyEncodableValue]

        enum CodingKeys: String, CodingKey {
            case name, description, parameters
        }
    }

    let model: String
    let messages: [Message]
    let tools: [Tool]?
    let stream: Bool
    let temperature: Double?
    let maxTokens: Int?

    enum CodingKeys: String, CodingKey {
        case model, messages, tools, stream, temperature
        case maxTokens = "max_tokens"
    }
}

private struct AnyEncodableValue: Encodable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let string as String:
            try container.encode(string)
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let array as [Any]:
            try container.encode(array.map { AnyEncodableValue($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyEncodableValue($0) })
        default:
            try container.encode(String(describing: value))
        }
    }
}

private struct OpenAIStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            struct ToolCall: Decodable {
                struct Function: Decodable {
                    let name: String?
                    let arguments: String?
                }

                let index: Int?
                let id: String?
                let function: Function?
            }

            let content: String?
            let toolCalls: [ToolCall]?

            enum CodingKeys: String, CodingKey {
                case content
                case toolCalls = "tool_calls"
            }
        }

        let delta: Delta?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }

    let choices: [Choice]?
}
