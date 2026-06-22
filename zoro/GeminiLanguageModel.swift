//
//  GeminiLanguageModel.swift
//  zoro
//
//  Created by Antigravity on 20/06/26.
//

import Foundation
import FoundationModels

// MARK: - Gemini Language Model Conformance

public struct GeminiLanguageModel: Sendable {
    public let modelName: String
    public let apiKey: String
    public let timeout: TimeInterval

    public init(
        modelName: String = "gemini-2.5-flash",
        apiKey: String,
        timeout: TimeInterval = 60
    ) {
        self.modelName = modelName
        self.apiKey = apiKey
        self.timeout = timeout
    }
}

extension GeminiLanguageModel: LanguageModel {
    public typealias Executor = GeminiExecutor

    public var capabilities: LanguageModelCapabilities {
        return LanguageModelCapabilities(capabilities: [.toolCalling])
    }

    public var executorConfiguration: GeminiExecutor.Configuration {
        return .init(
            modelName: modelName,
            apiKey: apiKey,
            timeout: timeout
        )
    }
}

// MARK: - Gemini Executor Conformance

public struct GeminiExecutor: LanguageModelExecutor {
    public typealias Model = GeminiLanguageModel

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
        model: GeminiLanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        let responseEntryID = UUID().uuidString
        let toolCallsEntryID = UUID().uuidString
        
        // 1. Build the REST URL
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(configuration.modelName):streamGenerateContent?alt=sse&key=\(configuration.apiKey)"
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "GeminiExecutor", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid Gemini API endpoint URL"])
        }
        
        // 2. Convert transcript entries to Gemini contents
        var contents: [GeminiRequest.Content] = []
        var systemInstruction: GeminiRequest.SystemInstruction? = nil
        
        for entry in request.transcript {
            switch entry {
            case .instructions(let instructions):
                let textContent = text(from: instructions.segments)
                systemInstruction = GeminiRequest.SystemInstruction(parts: [.init(text: textContent)])
                
            case .prompt(let prompt):
                let textContent = text(from: prompt.segments)
                contents.append(.init(role: "user", parts: [.init(text: textContent)]))
                
            case .toolCalls(let toolCalls):
                var parts: [GeminiRequest.Part] = []
                for call in toolCalls {
                    let argsData = call.arguments.jsonString.data(using: .utf8) ?? Data()
                    let argsDict = (try? JSONSerialization.jsonObject(with: argsData)) as? [String: Any]
                    let jsonArgs = argsDict?.mapValues { JSONValue.fromAny($0) }
                    let functionCall = GeminiRequest.FunctionCall(name: call.toolName, args: jsonArgs)
                    parts.append(.init(functionCall: functionCall))
                }
                contents.append(.init(role: "model", parts: parts))
                
            case .toolOutput(let toolOutput):
                let resultText = text(from: toolOutput.segments)
                let responseObj: [String: JSONValue]
                if let data = resultText.data(using: .utf8),
                   let jsonObj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    responseObj = jsonObj.mapValues { JSONValue.fromAny($0) }
                } else {
                    responseObj = ["result": .string(resultText)]
                }
                let functionResponse = GeminiRequest.FunctionResponse(name: toolOutput.toolName, response: responseObj)
                contents.append(.init(role: "user", parts: [.init(functionResponse: functionResponse)]))
                
            case .response(let response):
                let textContent = text(from: response.segments)
                contents.append(.init(role: "model", parts: [.init(text: textContent)]))
                
            case .reasoning:
                break
                
            @unknown default:
                break
            }
        }
        
        // Strictly alternate roles by merging consecutive turns of the same role
        let mergedContents = mergeConsecutiveContents(contents)
        
        // 3. Convert tools
        var functionDeclarations: [GeminiRequest.FunctionDeclaration] = []
        for toolDef in request.enabledToolDefinitions {
            let paramData = try? JSONEncoder().encode(toolDef.parameters)
            let paramJson = paramData.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
            let sanitizedParams = paramJson.map { sanitizeSchema($0) }
            
            let decl = GeminiRequest.FunctionDeclaration(
                name: toolDef.name,
                description: toolDef.description,
                parameters: sanitizedParams
            )
            functionDeclarations.append(decl)
        }
        let geminiTools = functionDeclarations.isEmpty ? nil : [GeminiRequest.Tool(functionDeclarations: functionDeclarations)]
        
        // 4. Construct request payload
        let geminiReq = GeminiRequest(
            contents: mergedContents,
            systemInstruction: systemInstruction,
            tools: geminiTools,
            generationConfig: .init(
                temperature: request.generationOptions.temperature,
                maxOutputTokens: request.generationOptions.maximumResponseTokens
            )
        )
        
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = configuration.timeout
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        urlRequest.httpBody = try encoder.encode(geminiReq)
        
        // 5. Run standard HTTP bytes session
        let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "GeminiExecutor", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])
        }
        
        if httpResponse.statusCode != 200 {
            var errorBody = ""
            for try await byte in bytes {
                if let char = String(bytes: [byte], encoding: .utf8) {
                    errorBody += char
                }
            }
            throw NSError(domain: "GeminiExecutor", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP error \(httpResponse.statusCode): \(errorBody)"])
        }
        
        var line = ""
        var sentToolCalls: Set<String> = []
        
        for try await byte in bytes {
            if byte == 10 { // Newline delimiter
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("data: ") {
                    let jsonString = String(trimmed.dropFirst(6))
                    if let data = jsonString.data(using: .utf8) {
                        do {
                            let responseObj = try JSONDecoder().decode(GeminiResponse.self, from: data)
                            if let candidates = responseObj.candidates {
                                for candidate in candidates {
                                    if let content = candidate.content, let parts = content.parts {
                                        for (partIndex, part) in parts.enumerated() {
                                            // Handle Text
                                            if let text = part.text, !text.isEmpty {
                                                await channel.send(.response(
                                                    entryID: responseEntryID,
                                                    action: .appendText(text, tokenCount: 1)
                                                ))
                                            }
                                            
                                            // Handle Singular Function Call
                                            if let call = part.functionCall {
                                                let key = "\(partIndex)_\(call.name)"
                                                if !sentToolCalls.contains(key) {
                                                    sentToolCalls.insert(key)
                                                    let callId = "call_\(UUID().uuidString.prefix(8).lowercased())"
                                                    
                                                    // Start
                                                    await channel.send(.toolCalls(
                                                        entryID: toolCallsEntryID,
                                                        action: .toolCall(id: callId, name: call.name, action: .appendArguments("", tokenCount: 0))
                                                    ))
                                                    // Arguments
                                                    let argsData = (try? JSONEncoder().encode(call.args ?? [:])) ?? Data()
                                                    let argsString = String(data: argsData, encoding: .utf8) ?? "{}"
                                                    await channel.send(.toolCalls(
                                                        entryID: toolCallsEntryID,
                                                        action: .toolCall(id: callId, name: call.name, action: .appendArguments(argsString, tokenCount: 1))
                                                    ))
                                                }
                                            }
                                            
                                            // Handle Plural Function Calls
                                            if let calls = part.functionCalls {
                                                for (callIndex, call) in calls.enumerated() {
                                                    let key = "\(partIndex)_\(callIndex)_\(call.name)"
                                                    if !sentToolCalls.contains(key) {
                                                        sentToolCalls.insert(key)
                                                        let callId = "call_\(UUID().uuidString.prefix(8).lowercased())"
                                                        
                                                        // Start
                                                        await channel.send(.toolCalls(
                                                            entryID: toolCallsEntryID,
                                                            action: .toolCall(id: callId, name: call.name, action: .appendArguments("", tokenCount: 0))
                                                        ))
                                                        // Arguments
                                                        let argsData = (try? JSONEncoder().encode(call.args ?? [:])) ?? Data()
                                                        let argsString = String(data: argsData, encoding: .utf8) ?? "{}"
                                                        await channel.send(.toolCalls(
                                                            entryID: toolCallsEntryID,
                                                            action: .toolCall(id: callId, name: call.name, action: .appendArguments(argsString, tokenCount: 1))
                                                        ))
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            
                            // Handle usage metadata
                            if let usage = responseObj.usageMetadata {
                                let inputTokens = usage.promptTokenCount ?? 0
                                let outputTokens = usage.candidatesTokenCount ?? 0
                                await channel.send(
                                    .response(
                                        entryID: responseEntryID,
                                        action: .updateUsage(
                                            input: .init(totalTokenCount: inputTokens, cachedTokenCount: 0),
                                            output: .init(totalTokenCount: outputTokens, reasoningTokenCount: 0)
                                        )
                                    )
                                )
                            }
                        } catch {
                            // Suppress decode errors (e.g. empty keep-alive ping data lines)
                        }
                    }
                }
                line = ""
            } else {
                if let char = String(bytes: [byte], encoding: .utf8) {
                    line += char
                }
            }
        }
    }
    
    // MARK: - Helper Methods
    
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
    
    private func mergeConsecutiveContents(_ contents: [GeminiRequest.Content]) -> [GeminiRequest.Content] {
        var merged: [GeminiRequest.Content] = []
        for content in contents {
            if let last = merged.last, last.role == content.role {
                let combinedParts = last.parts + content.parts
                merged[merged.count - 1] = GeminiRequest.Content(role: last.role, parts: combinedParts)
            } else {
                merged.append(content)
            }
        }
        return merged
    }
    
    private func sanitizeSchema(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let dict):
            var newDict: [String: JSONValue] = [:]
            for (k, v) in dict {
                if k == "type", case .string(let typeStr) = v {
                    newDict[k] = .string(typeStr.uppercased())
                } else if k == "properties", case .object(let props) = v {
                    newDict[k] = .object(props.mapValues { sanitizeSchema($0) })
                } else if k == "items" {
                    newDict[k] = sanitizeSchema(v)
                } else {
                    newDict[k] = v
                }
            }
            return .object(newDict)
        case .array(let arr):
            return .array(arr.map { sanitizeSchema($0) })
        default:
            return value
        }
    }
}

// MARK: - JSON Representation Definitions

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else if container.decodeNil() {
            self = .null
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid JSONValue")
        }
    }
    
    public func encode(to encoder: Encoder) throws {
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
    
    public static func fromAny(_ any: Any?) -> JSONValue {
        guard let any = any else { return .null }
        if let string = any as? String {
            return .string(string)
        } else if let number = any as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        } else if let bool = any as? Bool {
            return .bool(bool)
        } else if let double = any as? Double {
            return .number(double)
        } else if let int = any as? Int {
            return .number(Double(int))
        } else if let array = any as? [Any] {
            return .array(array.map { fromAny($0) })
        } else if let dict = any as? [String: Any] {
            return .object(dict.mapValues { fromAny($0) })
        }
        return .null
    }
}

// MARK: - Gemini REST Request Definitions

struct GeminiRequest: Codable {
    struct Content: Codable {
        let role: String
        let parts: [Part]
    }
    
    struct Part: Codable {
        let text: String?
        let functionCall: FunctionCall?
        let functionResponse: FunctionResponse?
        
        enum CodingKeys: String, CodingKey {
            case text
            case functionCall
            case functionResponse
        }
        
        init(text: String) {
            self.text = text
            self.functionCall = nil
            self.functionResponse = nil
        }
        
        init(functionCall: FunctionCall) {
            self.text = nil
            self.functionCall = functionCall
            self.functionResponse = nil
        }
        
        init(functionResponse: FunctionResponse) {
            self.text = nil
            self.functionCall = nil
            self.functionResponse = functionResponse
        }
    }
    
    struct FunctionCall: Codable {
        let name: String
        let args: [String: JSONValue]?
    }
    
    struct FunctionResponse: Codable {
        let name: String
        let response: [String: JSONValue]
    }
    
    struct SystemInstruction: Codable {
        let parts: [SystemPart]
        struct SystemPart: Codable {
            let text: String
        }
    }
    
    struct Tool: Codable {
        let functionDeclarations: [FunctionDeclaration]
    }
    
    struct FunctionDeclaration: Codable {
        let name: String
        let description: String
        let parameters: JSONValue?
    }
    
    struct GenerationConfig: Codable {
        let temperature: Double?
        let maxOutputTokens: Int?
    }
    
    let contents: [Content]
    let systemInstruction: SystemInstruction?
    let tools: [Tool]?
    let generationConfig: GenerationConfig?
}

// MARK: - Gemini REST Response Definitions

struct GeminiResponse: Codable {
    struct Candidate: Codable {
        let content: Content?
        let finishReason: String?
    }
    struct Content: Codable {
        let parts: [Part]?
    }
    struct Part: Codable {
        let text: String?
        let functionCall: FunctionCall?
        let functionCalls: [FunctionCall]?
    }
    struct FunctionCall: Codable {
        let name: String
        let args: [String: JSONValue]?
    }
    struct UsageMetadata: Codable {
        let promptTokenCount: Int?
        let candidatesTokenCount: Int?
        let totalTokenCount: Int?
    }
    
    let candidates: [Candidate]?
    let usageMetadata: UsageMetadata?
}
