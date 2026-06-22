//
//  SearchFilesTool.swift
//  zoro
//
//  Created by Antigravity on 19/06/26.
//

import Foundation
import FoundationModels

struct SearchFilesTool: Tool {
    let name = "search_files"
    let description = "Search the contents of text files in the workspace for a matching query string (like ripgrep)."
    
    @Generable
    struct Arguments {
        @Guide(description: "The string query to search for inside files")
        var query: String
    }
    
    func call(arguments: Arguments) async throws -> String {
        guard let workspaceURL = await WorkspaceManager.shared.workspaceURL else {
            return "Error: No workspace directory selected."
        }
        
        do {
            if let ripgrepResult = try await runRipgrep(query: arguments.query, workspaceURL: workspaceURL) {
                return ripgrepResult
            }
            // Fallback to native Swift search if ripgrep isn't found
            return try runSwiftSearch(query: arguments.query, workspaceURL: workspaceURL)
        } catch {
            return "Search error: \(error.localizedDescription)"
        }
    }
    
    private func runRipgrep(query: String, workspaceURL: URL) async throws -> String? {
        let fileManager = FileManager.default
        let rgPaths = ["/opt/homebrew/bin/rg", "/usr/local/bin/rg", "/usr/bin/rg"]
        var selectedPath: String? = nil
        for path in rgPaths {
            if fileManager.fileExists(atPath: path) {
                selectedPath = path
                break
            }
        }
        
        guard let rgPath = selectedPath else {
            return nil // Ripgrep is not available, trigger fallback
        }
        
        let process = Process()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.arguments = ["-n", "-H", "--no-heading", "--color=never", query, "."]
        process.launchPath = rgPath
        process.currentDirectoryURL = workspaceURL
        
        try process.run()
        let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        
        let status = process.terminationStatus
        if status == 0 || status == 1 {
            let result = String(data: data, encoding: .utf8) ?? ""
            return result.isEmpty ? "No matches found." : result
        } else {
            return nil // Treat other failures as fallback triggers
        }
    }
    
    private func runSwiftSearch(query: String, workspaceURL: URL) throws -> String {
        let fileManager = FileManager.default
        var results = [String]()
        
        guard let enumerator = fileManager.enumerator(
            at: workspaceURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return "Error: Unable to enumerate workspace files."
        }
        
        for case let fileURL as URL in enumerator {
            let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard resourceValues.isRegularFile == true else { continue }
            
            let path = fileURL.path
            // Exclude directories to avoid search lag
            if path.contains("/.git/") || path.contains("/node_modules/") || path.contains("/.venv/") || path.contains("/venv/") || path.contains("/Build/") || path.contains("/DerivedData/") {
                continue
            }
            
            do {
                let data = try Data(contentsOf: fileURL)
                guard let content = String(data: data, encoding: .utf8) else { continue }
                
                let lines = content.components(separatedBy: .newlines)
                for (index, line) in lines.enumerated() {
                    if line.contains(query) {
                        let relativePath = fileURL.path.replacingOccurrences(of: workspaceURL.path + "/", with: "")
                        results.append("\(relativePath):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                        if results.count >= 200 {
                            results.append("... cap of 200 matches reached.")
                            break
                        }
                    }
                }
            } catch {
                continue // Skip binary or unreadable files silently
            }
            
            if results.count >= 200 {
                break
            }
        }
        
        return results.isEmpty ? "No matches found." : results.joined(separator: "\n")
    }
}
