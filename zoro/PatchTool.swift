//
//  PatchTool.swift
//  zoro
//
//  Created by Antigravity on 19/06/26.
//

import Foundation
import FoundationModels

struct PatchTool: Tool {
    let name = "patch"
    let description = "Edit a file by replacing a unique contiguous block of code/text (find) with another block (replace). This is the preferred method for editing existing files."
    
    @Generable
    struct Arguments {
        @Guide(description: "The relative path of the file to edit")
        var path: String
        
        @Guide(description: "The exact contiguous block of code/text to find. This block must be unique in the file and match exactly, including leading spaces, tabs, and newlines.")
        var find: String
        
        @Guide(description: "The new code/text to replace the find block with")
        var replace: String
    }
    
    func call(arguments: Arguments) async throws -> String {
        guard let workspaceURL = await WorkspaceManager.shared.workspaceURL else {
            return "Error: No workspace directory selected."
        }
        
        let fileURL = workspaceURL.appendingPathComponent(arguments.path)
        let fileManager = FileManager.default
        
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return "Error: File does not exist at path '\(arguments.path)'."
        }
        
        do {
            let data = try Data(contentsOf: fileURL)
            guard let content = String(data: data, encoding: .utf8) else {
                return "Error: File '\(arguments.path)' is not a UTF-8 encoded text file."
            }
            
            let occurrences = content.components(separatedBy: arguments.find).count - 1
            if occurrences == 0 {
                var errorMsg = "Error: The target block was not found in '\(arguments.path)'.\n\nEnsure that:\n1. Your 'find' block matches the exact spacing, indentation, and newlines in the file.\n2. You copy the block precisely.\n"
                
                let findLines = arguments.find.components(separatedBy: .newlines)
                if let firstLine = findLines.first?.trimmingCharacters(in: .whitespacesAndNewlines), !firstLine.isEmpty {
                    let fileLines = content.components(separatedBy: .newlines)
                    var lineMatches = [String]()
                    for (index, line) in fileLines.enumerated() {
                        if line.contains(firstLine) {
                            lineMatches.append("Line \(index + 1): \(line)")
                        }
                    }
                    if !lineMatches.isEmpty {
                        errorMsg += "\nWe found similar lines in the file that might match the start of your block:\n"
                        errorMsg += lineMatches.prefix(5).joined(separator: "\n")
                    }
                }
                return errorMsg
            } else if occurrences > 1 {
                return "Error: The target block is ambiguous. It was found \(occurrences) times in '\(arguments.path)'. Please add more surrounding context lines (lines before and after) to your 'find' parameter to make it unique."
            }
            
            let updatedContent = content.replacingOccurrences(of: arguments.find, with: arguments.replace)
            try updatedContent.write(to: fileURL, atomically: true, encoding: .utf8)
            return "Successfully patched '\(arguments.path)'"
        } catch {
            return "Error applying patch to '\(arguments.path)': \(error.localizedDescription)"
        }
    }
}
