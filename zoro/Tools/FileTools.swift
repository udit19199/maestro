//
//  FileTools.swift
//  zoro
//

import Foundation
import FoundationModels

// MARK: - ListDirectoryTool
@MainActor
struct ListDirectoryTool: Tool {
    let name = "list_directory"
    let description = "List files and folders in the workspace at the specified relative path."
    let executionContext: AgentExecutionContext

    @Generable
    struct Arguments {
        @Guide(description: "The relative path to list, use '.' or empty string for the workspace root")
        var path: String
    }

    func call(arguments: Arguments) async throws -> String {
        if let permissionError = SecurityPolicy.toolPermissionError(for: name, context: executionContext) {
            return permissionError
        }
        guard let workspaceURL = WorkspaceManager.shared.workspaceURL else {
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
    let executionContext: AgentExecutionContext

    @Generable
    struct Arguments {
        @Guide(description: "The relative path of the file to read")
        var path: String
    }

    func call(arguments: Arguments) async throws -> String {
        if let permissionError = SecurityPolicy.toolPermissionError(for: name, context: executionContext) {
            return permissionError
        }
        guard let workspaceURL = WorkspaceManager.shared.workspaceURL else {
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
    let executionContext: AgentExecutionContext

    @Generable
    struct Arguments {
        @Guide(description: "The relative path of the file to write")
        var path: String

        @Guide(description: "The complete content to write to the file")
        var content: String
    }

    func call(arguments: Arguments) async throws -> String {
        if let permissionError = SecurityPolicy.toolPermissionError(for: name, context: executionContext) {
            return permissionError
        }
        guard let workspaceURL = WorkspaceManager.shared.workspaceURL else {
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

