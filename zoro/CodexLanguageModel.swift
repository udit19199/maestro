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
        self.modelName = modelName
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

    private static let responsesURL = URL(string: "https://chatgpt.com/backend-api/codex/responses")!

    public struct Configuration: Hashable, Sendable {
        public let modelName: String
        public let timeout: TimeInterval

        public init(modelName: String, timeout: TimeInterval) {
            self.modelName = modelName
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
        let credentials = try await CodexAuthManager.shared.getValidCredentials()

        let responseEntryID = UUID().uuidString
        let toolCallsEntryID = UUID().uuidString

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

        inputItems = Self.stripReasoningItems(inputItems)

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

        var payload: [String: CodexJSONValue] = [
            "model": .string(configuration.modelName),
            "input": .array(inputItems),
            "stream": .bool(true),
            "store": .bool(false)
        ]

        if let instructions, !instructions.isEmpty {
            payload["instructions"] = .string(instructions)
        }

        if !tools.isEmpty {
            payload["tools"] = .array(tools)
        }

        if let temperature = request.generationOptions.temperature {
            payload["temperature"] = .number(temperature)
        }

        var urlRequest = URLRequest(url: Self.responsesURL)
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
                userInfo: [NSLocalizedDescriptionKey: "Codex HTTP error \(httpResponse.statusCode): \(errorBody)"]
            )
        }

        var line = ""
        var sentToolCalls: Set<String> = []

        for try await byte in bytes {
            if byte == 10 {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("data: ") {
                    let jsonString = String(trimmed.dropFirst(6))
                    if jsonString == "[DONE]" { break }

                    guard let data = jsonString.data(using: .utf8),
                          let event = try? JSONDecoder().decode(CodexStreamEvent.self, from: data) else {
                        line = ""
                        continue
                    }

                    switch event.type {
                    case "response.output_text.delta":
                        if let delta = event.delta, !delta.isEmpty {
                            await channel.send(.response(
                                entryID: responseEntryID,
                                action: .appendText(delta, tokenCount: 1)
                            ))
                        }

                    case "response.output_item.done":
                        if let item = event.item,
                           let itemType = item["type"]?.stringValue,
                           itemType == "function_call" {
                            let callID = item["call_id"]?.stringValue ?? "call_\(UUID().uuidString.prefix(8).lowercased())"
                            let name = item["name"]?.stringValue ?? ""
                            let args = item["arguments"]?.stringValue ?? "{}"
                            let key = "\(callID)_\(name)"
                            if !sentToolCalls.contains(key) {
                                sentToolCalls.insert(key)
                                await channel.send(.toolCalls(
                                    entryID: toolCallsEntryID,
                                    action: .toolCall(id: callID, name: name, action: .appendArguments("", tokenCount: 0))
                                ))
                                await channel.send(.toolCalls(
                                    entryID: toolCallsEntryID,
                                    action: .toolCall(id: callID, name: name, action: .appendArguments(args, tokenCount: 1))
                                ))
                            }
                        }

                    case "response.completed":
                        if let usage = event.response?.usage {
                            await channel.send(.response(
                                entryID: responseEntryID,
                                action: .updateUsage(
                                    input: .init(totalTokenCount: usage.inputTokens ?? 0, cachedTokenCount: 0),
                                    output: .init(totalTokenCount: usage.outputTokens ?? 0, reasoningTokenCount: 0)
                                )
                            ))
                        }

                    default:
                        break
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

    private static func stripReasoningItems(_ items: [CodexJSONValue]) -> [CodexJSONValue] {
        items.filter { item in
            guard case .object(let dict) = item else { return true }
            return dict["type"]?.stringValue != "reasoning"
        }
    }
}

// MARK: - Codex JSON helpers

enum CodexJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: CodexJSONValue])
    case array([CodexJSONValue])
    case null

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let array = try? container.decode([CodexJSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: CodexJSONValue].self) {
            self = .object(object)
        } else if container.decodeNil() {
            self = .null
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid CodexJSONValue")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let string):
            try container.encode(string)
        case .number(let number):
            try container.encode(number)
        case .bool(let bool):
            try container.encode(bool)
        case .array(let array):
            try container.encode(array)
        case .object(let object):
            try container.encode(object)
        case .null:
            try container.encodeNil()
        }
    }
}

private struct CodexStreamEvent: Decodable {
    struct ResponsePayload: Decodable {
        struct Usage: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
            }
        }

        let usage: Usage?
    }

    let type: String
    let delta: String?
    let item: [String: CodexJSONValue]?
    let response: ResponsePayload?
}
