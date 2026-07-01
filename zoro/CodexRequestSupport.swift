//
//  CodexRequestSupport.swift
//  zoro
//
//  Codex Responses API payload helpers and SSE parsing (Foundation only).
//

import Foundation

enum CodexRequestSupport {
    static let responsesEndpoint = "https://chatgpt.com/backend-api/codex/responses"

    static func stripReasoningItems(_ items: [CodexJSONValue]) -> [CodexJSONValue] {
        items.filter { item in
            guard case .object(let dict) = item else { return true }
            return dict["type"]?.stringValue != "reasoning"
        }
    }

    static func buildRequestPayload(
        modelName: String,
        instructions: String?,
        inputItems: [CodexJSONValue],
        tools: [CodexJSONValue],
        temperature: Double?
    ) -> [String: CodexJSONValue] {
        var payload: [String: CodexJSONValue] = [
            "model": .string(modelName),
            "input": .array(stripReasoningItems(inputItems)),
            "stream": .bool(true),
            "store": .bool(false)
        ]

        if let instructions, !instructions.isEmpty {
            payload["instructions"] = .string(instructions)
        }

        if !tools.isEmpty {
            payload["tools"] = .array(tools)
        }

        if let temperature {
            payload["temperature"] = .number(temperature)
        }

        return payload
    }
}

enum CodexStreamAction: Equatable {
    case appendText(String)
    case startToolCall(id: String, name: String)
    case appendToolArguments(id: String, delta: String)
    case completeToolCall(id: String, name: String, arguments: String)
    case updateUsage(inputTokens: Int, outputTokens: Int)
    case failed(String)
}

struct CodexStreamParser {
    private struct PendingToolCall {
        var name: String
        var arguments: String
    }

    private var pendingToolCalls: [String: PendingToolCall] = [:]
    private var completedToolCallKeys: Set<String> = []

    mutating func reset() {
        pendingToolCalls = [:]
        completedToolCallKeys = []
    }

    mutating func consume(eventJSON: String) throws -> [CodexStreamAction] {
        guard let data = eventJSON.data(using: .utf8),
              let event = try? JSONDecoder().decode(CodexStreamEvent.self, from: data) else {
            return []
        }

        switch event.type {
        case "response.output_text.delta":
            guard let delta = event.delta, !delta.isEmpty else { return [] }
            return [.appendText(delta)]

        case "response.output_item.added":
            return handleOutputItemAdded(event.item)

        case "response.function_call_arguments.delta":
            guard let itemID = event.itemID, let delta = event.delta else { return [] }
            if pendingToolCalls[itemID] == nil {
                pendingToolCalls[itemID] = PendingToolCall(name: event.name ?? "", arguments: "")
            }
            pendingToolCalls[itemID]?.arguments += delta
            return [.appendToolArguments(id: itemID, delta: delta)]

        case "response.function_call_arguments.done":
            guard let itemID = event.itemID else { return [] }
            let name = event.name ?? pendingToolCalls[itemID]?.name ?? ""
            let arguments = event.arguments ?? pendingToolCalls[itemID]?.arguments ?? "{}"
            pendingToolCalls.removeValue(forKey: itemID)
            return finalizeToolCall(id: itemID, name: name, arguments: arguments)

        case "response.output_item.done":
            return handleOutputItemDone(event.item)

        case "response.completed":
            if let usage = event.response?.usage {
                return [.updateUsage(
                    inputTokens: usage.inputTokens ?? 0,
                    outputTokens: usage.outputTokens ?? 0
                )]
            }
            return []

        case "response.failed", "response.incomplete", "error":
            throw CodexStreamFailure(CodexAuthSupport.sanitizedErrorDetail(eventJSON))

        default:
            return []
        }
    }

    private mutating func handleOutputItemAdded(_ item: [String: CodexJSONValue]?) -> [CodexStreamAction] {
        guard let item,
              item["type"]?.stringValue == "function_call" else {
            return []
        }

        let callID = item["call_id"]?.stringValue ?? item["id"]?.stringValue ?? ""
        guard !callID.isEmpty else { return [] }

        let name = item["name"]?.stringValue ?? ""
        pendingToolCalls[callID] = PendingToolCall(name: name, arguments: item["arguments"]?.stringValue ?? "")
        return [.startToolCall(id: callID, name: name)]
    }

    private mutating func handleOutputItemDone(_ item: [String: CodexJSONValue]?) -> [CodexStreamAction] {
        guard let item,
              item["type"]?.stringValue == "function_call" else {
            return []
        }

        let callID = item["call_id"]?.stringValue ?? item["id"]?.stringValue ?? ""
        guard !callID.isEmpty else { return [] }

        let name = item["name"]?.stringValue ?? pendingToolCalls[callID]?.name ?? ""
        let arguments = item["arguments"]?.stringValue ?? pendingToolCalls[callID]?.arguments ?? "{}"
        pendingToolCalls.removeValue(forKey: callID)
        return finalizeToolCall(id: callID, name: name, arguments: arguments)
    }

    private mutating func finalizeToolCall(id: String, name: String, arguments: String) -> [CodexStreamAction] {
        let key = "\(id)_\(name)"
        guard !completedToolCallKeys.contains(key) else { return [] }
        completedToolCallKeys.insert(key)
        return [.completeToolCall(id: id, name: name, arguments: arguments)]
    }
}

struct CodexStreamFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

struct CodexStreamEvent: Decodable {
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
    let itemID: String?
    let name: String?
    let arguments: String?

    enum CodingKeys: String, CodingKey {
        case type
        case delta
        case item
        case response
        case itemID = "item_id"
        case name
        case arguments
    }
}
