//
//  TavilySearchTool.swift
//  zoro
//
//  Created by Antigravity on 19/06/26.
//

import Foundation
import FoundationModels

@MainActor
struct TavilySearchTool: Tool {
    let name = "tavily_search"
    let description = "Search the web and perform deep research using the Tavily API. Returns a list of matching search results or a synthesized research answer."

    @Generable
    struct Arguments {
        @Guide(description: "The search query or topic to research")
        var query: String
        
        @Guide(description: "Search depth: 'basic' for quick searches, or 'advanced' for deep research runs. Defaults to 'basic'.")
        var searchDepth: String?
        
        @Guide(description: "Maximum number of search results to return. Defaults to 5.")
        var maxResults: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        // Retrieve the API key from macOS Keychain
        guard let apiKey = KeychainHelper.retrieve(key: "tavily_api_key"), !apiKey.isEmpty else {
            return "Error: Tavily API Key is missing. Please enter your Tavily API Key in the Settings panel of the Zoro app."
        }
        
        let url = URL(string: "https://api.tavily.com/search")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let depth = arguments.searchDepth ?? "basic"
        let maxRes = arguments.maxResults ?? 5
        
        let payload: [String: Any] = [
            "api_key": apiKey,
            "query": arguments.query,
            "search_depth": depth,
            "include_answer": true,
            "max_results": maxRes
        ]
        
        let stepId = await WorkspaceManager.shared.addResearchStep("Searching Web: \(arguments.query) (\(depth) depth)")
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: payload, options: [])
            request.httpBody = jsonData
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                await WorkspaceManager.shared.failResearchStep(id: stepId)
                return "Error: Received invalid network response from Tavily."
            }
            
            guard httpResponse.statusCode == 200 else {
                await WorkspaceManager.shared.failResearchStep(id: stepId)
                let errorMsg = String(data: data, encoding: .utf8) ?? "Status code: \(httpResponse.statusCode)"
                return "Error: Tavily API request failed. Details: \(errorMsg)"
            }
            
            let decoder = JSONDecoder()
            let tavilyResponse = try decoder.decode(TavilyResponse.self, from: data)
            
            var lines = [String]()
            lines.append("### Web Research Results for: '\(arguments.query)'")
            
            if let answer = tavilyResponse.answer, !answer.isEmpty {
                lines.append("\n**Synthesized Answer:**\n\(answer)\n")
            }
            
            lines.append("\n**Sources Found:**")
            for (idx, result) in tavilyResponse.results.enumerated() {
                lines.append("\(idx + 1). [\(result.title)](\(result.url)) (Score: \(result.score))")
                lines.append("   *Summary:* \(result.content)\n")
            }
            
            await WorkspaceManager.shared.completeResearchStep(id: stepId)
            return lines.joined(separator: "\n")
            
        } catch {
            await WorkspaceManager.shared.failResearchStep(id: stepId)
            return "Error executing web search: \(error.localizedDescription)"
        }
    }
}

// Response Structures
private struct TavilyResponse: Codable {
    let results: [TavilyResult]
    let answer: String?
}

private struct TavilyResult: Codable {
    let title: String
    let url: String
    let content: String
    let score: Double
}
