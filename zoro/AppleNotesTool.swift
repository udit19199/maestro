//
//  AppleNotesTool.swift
//  zoro
//
//  Created by Antigravity on 19/06/26.
//

import Foundation
import FoundationModels

struct AppleNotesTool: Tool {
    let name = "manage_apple_notes"
    let description = "Create, read, search, list, and append to notes inside the native macOS Apple Notes app. Output will sync to iCloud automatically."

    @Generable
    struct Arguments {
        @Guide(description: "The action to perform: 'create_note', 'list_notes', 'search_notes', 'read_note', 'append_note'")
        var action: String
        
        @Guide(description: "The title of the note (used for create_note)")
        var title: String?
        
        @Guide(description: "The content/body of the note (Markdown or text)")
        var body: String?
        
        @Guide(description: "The query string (used for search_notes)")
        var query: String?
        
        @Guide(description: "The unique ID of the note (used for read_note and append_note)")
        var noteId: String?
    }

    func call(arguments: Arguments) async throws -> String {
        switch arguments.action {
        case "create_note":
            guard let title = arguments.title, let body = arguments.body else {
                return "Error: Missing required fields ('title', 'body') for 'create_note'."
            }
            let stepId = await WorkspaceManager.shared.addResearchStep("Creating Apple Note: \(title)")
            let htmlBody = convertToHTML(title: title, markdown: body)
            let script = """
            tell application "Notes"
                tell folder "Notes" of default account
                    set newNote to make new note with properties {body:"\(escapeForAppleScript(htmlBody))"}
                    return id of newNote
                end tell
            end tell
            """
            do {
                let noteId = try await runAppleScript(script).trimmingCharacters(in: .whitespacesAndNewlines)
                await WorkspaceManager.shared.completeResearchStep(id: stepId)
                return "Successfully created note '\(title)' (ID: \(noteId))"
            } catch {
                await WorkspaceManager.shared.failResearchStep(id: stepId)
                return "Error creating note: \(error.localizedDescription)"
            }
            
        case "list_notes":
            let script = """
            tell application "Notes"
                set noteList to {}
                repeat with aNote in notes
                    set end of noteList to (id of aNote as string) & "::" & (name of aNote as string)
                end repeat
                return noteList
            end tell
            """
            do {
                let result = try await runAppleScript(script)
                return parseNoteList(result)
            } catch {
                return "Error listing notes: \(error.localizedDescription)"
            }
            
        case "search_notes":
            guard let query = arguments.query else {
                return "Error: Missing 'query' for 'search_notes'."
            }
            let script = """
            tell application "Notes"
                set matchingNotes to {}
                repeat with aNote in notes
                    if name of aNote contains "\(escapeForAppleScript(query))" or body of aNote contains "\(escapeForAppleScript(query))" then
                        set end of matchingNotes to (id of aNote as string) & "::" & (name of aNote as string)
                    end if
                end repeat
                return matchingNotes
            end tell
            """
            do {
                let result = try await runAppleScript(script)
                return parseNoteList(result)
            } catch {
                return "Error searching notes: \(error.localizedDescription)"
            }
            
        case "read_note":
            guard let noteId = arguments.noteId else {
                return "Error: Missing 'noteId' to read note."
            }
            let script = """
            tell application "Notes"
                return body of note id "\(escapeForAppleScript(noteId))"
            end tell
            """
            do {
                let htmlResult = try await runAppleScript(script)
                let plainText = stripHTML(from: htmlResult)
                return plainText
            } catch {
                return "Error reading note: \(error.localizedDescription)"
            }
            
        case "append_note":
            guard let noteId = arguments.noteId, let bodyToAppend = arguments.body else {
                return "Error: Missing required fields ('noteId', 'body') for 'append_note'."
            }
            let stepId = await WorkspaceManager.shared.addResearchStep("Appending to Apple Note ID: \(noteId)")
            // To append, we first read the current body, then write back the combined body
            let readScript = """
            tell application "Notes"
                return body of note id "\(escapeForAppleScript(noteId))"
            end tell
            """
            do {
                let currentHtml = try await runAppleScript(readScript)
                let appendHtml = convertToHTML(title: nil, markdown: bodyToAppend)
                let combinedHtml = currentHtml + "<br/>" + appendHtml
                
                let writeScript = """
                tell application "Notes"
                    set body of note id "\(escapeForAppleScript(noteId))" to "\(escapeForAppleScript(combinedHtml))"
                end tell
                """
                _ = try await runAppleScript(writeScript)
                await WorkspaceManager.shared.completeResearchStep(id: stepId)
                return "Successfully appended content to note."
            } catch {
                await WorkspaceManager.shared.failResearchStep(id: stepId)
                return "Error appending to note: \(error.localizedDescription)"
            }
            
        default:
            return "Error: Invalid action '\(arguments.action)'."
        }
    }

    // Helper to run AppleScript via process execution
    private func runAppleScript(_ script: String) async throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.arguments = ["-e", script]
        process.launchPath = "/usr/bin/osascript"
        
        try process.run()
        
        let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            let errData = try? pipe.fileHandleForReading.readToEnd()
            let errStr = errData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            throw NSError(domain: "AppleScriptError", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errStr])
        }
        
        return String(data: data, encoding: .utf8) ?? ""
    }

    // Convert markdown/plain text to HTML needed by Apple Notes
    private func convertToHTML(title: String?, markdown: String) -> String {
        let lines = markdown.components(separatedBy: .newlines)
        var html = ""
        
        if let title = title {
            html += "<h1>\(title)</h1>"
        }
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                html += "<div><br/></div>"
            } else if trimmed.hasPrefix("# ") {
                html += "<h2>\(trimmed.replacingOccurrences(of: "# ", with: ""))</h2>"
            } else if trimmed.hasPrefix("## ") {
                html += "<h3>\(trimmed.replacingOccurrences(of: "## ", with: ""))</h3>"
            } else {
                html += "<div>\(trimmed)</div>"
            }
        }
        return html
    }

    // Parse comma-separated list return from AppleScript
    private func parseNoteList(_ appleScriptOutput: String) -> String {
        let trimmed = appleScriptOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "missing value" {
            return "No notes found."
        }
        
        let items = trimmed.components(separatedBy: ", ")
        var resultLines = ["Notes in Apple Notes:"]
        
        for item in items {
            let parts = item.components(separatedBy: "::")
            if parts.count >= 2 {
                let id = parts[0]
                let name = parts[1]
                resultLines.append("- [\(id)] \(name)")
            } else {
                resultLines.append("- \(item)")
            }
        }
        
        return resultLines.joined(separator: "\n")
    }

    // Strip HTML to return readable text to the model
    private func stripHTML(from html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "<br/>", with: "\n")
        text = text.replacingOccurrences(of: "<br>", with: "\n")
        text = text.replacingOccurrences(of: "</div>", with: "\n")
        text = text.replacingOccurrences(of: "</p>", with: "\n")
        text = text.replacingOccurrences(of: "</h1>", with: "\n\n")
        text = text.replacingOccurrences(of: "</h2>", with: "\n\n")
        text = text.replacingOccurrences(of: "</h3>", with: "\n\n")
        
        let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: .caseInsensitive)
        let range = NSRange(location: 0, length: text.utf16.count)
        text = regex?.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "") ?? text
        
        // Remove excessive empty lines
        let lines = text.components(separatedBy: .newlines)
        let filtered = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        return filtered.joined(separator: "\n")
    }

    // Escape special characters for AppleScript string injection
    private func escapeForAppleScript(_ text: String) -> String {
        var escaped = text
        escaped = escaped.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        return escaped
    }
}
