//
//  FileTools.swift
//  zoro
//
//  Created by Antigravity on 19/06/26.
//

import Foundation
import FoundationModels

// MARK: - ListDirectoryTool
@MainActor
struct ListDirectoryTool: Tool {
    let name = "list_directory"
    let description = "List files and folders in the workspace at the specified relative path."

    @Generable
    struct Arguments {
        @Guide(description: "The relative path to list, use '.' or empty string for the workspace root")
        var path: String
    }

    func call(arguments: Arguments) async throws -> String {
        let workspace = await WorkspaceManager.shared
        if let permissionError = await workspace.toolPermissionError(for: name) {
            return permissionError
        }
        guard let workspaceURL = workspace.workspaceURL else {
            return "Error: No workspace directory selected."
        }

        switch SecurityPolicy.resolveWorkspacePath(arguments.path, relativeTo: workspaceURL) {
        case .failure(let error):
            return error.message
        case .success(let targetURL):
            let fileManager = FileManager.default
            do {
                let contents = try fileManager.contentsOfDirectory(
                    at: targetURL,
                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                    options: []
                )

                if contents.isEmpty {
                    return "Directory is empty."
                }

                var lines = [String]()
                for url in contents {
                    let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                    let isDir = resourceValues.isDirectory ?? false
                    let size = resourceValues.fileSize ?? 0
                    let name = url.lastPathComponent
                    let typeStr = isDir ? "[DIR]" : "[FILE (\(size) bytes)]"
                    lines.append("\(typeStr) \(name)")
                }
                return lines.sorted().joined(separator: "\n")
            } catch {
                return "Error listing directory: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - ReadFileTool
@MainActor
struct ReadFileTool: Tool {
    let name = "read_file"
    let description = "Read the entire contents of a text file in the workspace."

    @Generable
    struct Arguments {
        @Guide(description: "The relative path of the file to read")
        var path: String
    }

    func call(arguments: Arguments) async throws -> String {
        let workspace = await WorkspaceManager.shared
        if let permissionError = await workspace.toolPermissionError(for: name) {
            return permissionError
        }
        guard let workspaceURL = workspace.workspaceURL else {
            return "Error: No workspace directory selected."
        }

        switch SecurityPolicy.resolveWorkspacePath(arguments.path, relativeTo: workspaceURL) {
        case .failure(let error):
            return error.message
        case .success(let fileURL):
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                let fileSize = attributes[.size] as? Int64 ?? 0
                if fileSize > SecurityPolicy.maxFileReadBytes {
                    return "Error: File exceeds the \(SecurityPolicy.maxFileReadBytes) byte read limit."
                }

                let data = try Data(contentsOf: fileURL)
                guard let content = String(data: data, encoding: .utf8) else {
                    return "Error: File is not a UTF-8 text file."
                }
                return content
            } catch {
                return "Error reading file: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - WriteFileTool
@MainActor
struct WriteFileTool: Tool {
    let name = "write_file"
    let description = "Create a new file or completely overwrite an existing file with the specified content."

    @Generable
    struct Arguments {
        @Guide(description: "The relative path of the file to write")
        var path: String

        @Guide(description: "The complete content to write to the file")
        var content: String
    }

    func call(arguments: Arguments) async throws -> String {
        let workspace = await WorkspaceManager.shared
        if let permissionError = await workspace.toolPermissionError(for: name) {
            return permissionError
        }
        guard let workspaceURL = workspace.workspaceURL else {
            return "Error: No workspace directory selected."
        }

        switch SecurityPolicy.resolveWorkspacePath(arguments.path, relativeTo: workspaceURL) {
        case .failure(let error):
            return error.message
        case .success(let fileURL):
            let fileManager = FileManager.default
            let directoryURL = fileURL.deletingLastPathComponent()
            do {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
                try arguments.content.write(to: fileURL, atomically: true, encoding: .utf8)
                return "Successfully wrote to \(arguments.path)"
            } catch {
                return "Error writing file: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - ReplaceFileContentTool
@MainActor
struct ReplaceFileContentTool: Tool {
    let name = "replace_file_content"
    let description = "Edit a single contiguous block of code/text in a file by replacing a target string with a new string."

    @Generable
    struct Arguments {
        @Guide(description: "The relative path of the file to edit")
        var path: String

        @Guide(description: "The exact contiguous block of text/code to find in the file. Must match exactly.")
        var target: String

        @Guide(description: "The new text/code to replace the target block with")
        var replacement: String
    }

    func call(arguments: Arguments) async throws -> String {
        let workspace = await WorkspaceManager.shared
        if let permissionError = await workspace.toolPermissionError(for: name) {
            return permissionError
        }
        guard let workspaceURL = workspace.workspaceURL else {
            return "Error: No workspace directory selected."
        }

        switch SecurityPolicy.resolveWorkspacePath(arguments.path, relativeTo: workspaceURL) {
        case .failure(let error):
            return error.message
        case .success(let fileURL):
            do {
                let data = try Data(contentsOf: fileURL)
                guard let content = String(data: data, encoding: .utf8) else {
                    return "Error: File is not a UTF-8 text file."
                }

                let occurrences = content.components(separatedBy: arguments.target).count - 1
                if occurrences == 0 {
                    return "Error: Target string not found in the file. Ensure the target string matches the file contents exactly, including leading spaces and newlines."
                } else if occurrences > 1 {
                    return "Error: Target string is ambiguous (found \(occurrences) times). Provide more context lines around the target content to make it unique."
                }

                let updatedContent = content.replacingOccurrences(of: arguments.target, with: arguments.replacement)
                try updatedContent.write(to: fileURL, atomically: true, encoding: .utf8)
                return "Successfully updated \(arguments.path)"
            } catch {
                return "Error editing file: \(error.localizedDescription)"
            }
        }
    }
}
