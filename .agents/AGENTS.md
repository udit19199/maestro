# Zoro — Project Rules for AI Agents

## Project Overview

Zoro is a native **macOS SwiftUI application** that serves as an AI-powered personal assistant with tool-calling capabilities. It uses Apple's `FoundationModels` framework to interface with on-device Apple Intelligence, Apple Private Cloud Compute, and Anthropic Claude (via `ClaudeForFoundationModels`). The assistant can read/write files, run terminal commands, manage calendar events and reminders, search the web, and interact with Apple Notes — all scoped to a user-selected workspace directory.

- **Platform**: macOS 27.0+
- **Language**: Swift 5 (uses modern Swift concurrency: `async/await`, `Task`, `CheckedContinuation`)
- **UI Framework**: SwiftUI (AppKit is used only for `NSOpenPanel` and `NSColor` system colors)
- **Bundle Identifier**: `uditagarwal.zoro`

---

## Architecture

### High-Level Structure

```
zoro/
├── zoroApp.swift            # @main App entry point
├── ContentView.swift        # Single-view architecture: chat UI, settings, session management
├── WorkspaceManager.swift   # Singleton state manager (workspace, processes, todos, research)
├── KeychainHelper.swift     # macOS Keychain wrapper for API key storage
├── *Tool.swift              # Individual tool implementations conforming to `Tool` protocol
```

### Key Patterns

1. **Single-View App**: The entire UI lives in `ContentView.swift`. There is no navigation stack or multi-window setup. Subviews like `MessageBubble` are defined as separate structs in the same file.

2. **Singleton State Manager**: `WorkspaceManager` is an `ObservableObject` singleton accessed via `WorkspaceManager.shared`. It owns all shared state: workspace URL, active processes, todos, research steps, and clarification continuations.

3. **Tool Protocol**: Each tool is a `struct` conforming to the `Tool` protocol from `FoundationModels`. Every tool follows the same pattern:
   - A `name` constant (the tool identifier used by the LLM)
   - A `description` constant (human-readable purpose)
   - A nested `@Generable struct Arguments` with `@Guide` annotations on each field
   - A `func call(arguments:) async throws -> String` implementation

4. **Lazy Session Creation**: LLM sessions are created lazily via `getOrCreateSession()` and reset on workspace/model changes.

5. **Streaming Responses**: The chat uses `activeSession.streamResponse(to:)` for real-time token streaming.

---

## Coding Conventions

### Naming
- **Files**: PascalCase. Tool files are named `<ToolName>Tool.swift` (e.g., `CommandLineTool.swift`, `PatchTool.swift`).
- **Types**: PascalCase for structs, classes, enums, and protocols.
- **Properties & Methods**: camelCase. Use descriptive names (e.g., `runCommandBackground`, `activeClarificationQuestion`).
- **Tool Names** (the `name` constant): snake_case strings matching what the LLM references (e.g., `"run_terminal_command"`, `"search_files"`).

### Style
- Use `// MARK: -` section headers to separate logical groups within a file (see `FileTools.swift`).
- Use Xcode's default file header comment block (`// Created by ... on ...`).
- Prefer inline comments that explain *why*, not *what*, unless the code is educational in nature (see `WorkspaceManager.swift` for examples of explanatory comments aimed at learning).
- Keep `import` statements minimal — only import frameworks that are directly used.

### Error Handling
- Tools return error messages as `String` values (e.g., `"Error: No workspace directory selected."`) rather than throwing. This keeps the LLM's tool loop stable.
- Use `guard let ... else { return "Error: ..." }` for early validation of required fields.
- Errors surfaced to the user in the chat include actionable tips (e.g., "Tip: Click the gear icon...").

### Concurrency
- Use Swift's structured concurrency (`async/await`, `Task { }`) for all asynchronous work.
- Use `DispatchQueue.main.async` (not `@MainActor`) for publishing `@Published` property changes from background contexts in `WorkspaceManager`.
- Use `withCheckedContinuation` / `withCheckedThrowingContinuation` for bridging callback-based APIs (e.g., EventKit permissions, ClarifyTool suspension).

### Secrets Management
- API keys (Anthropic, Tavily) are stored in the macOS Keychain via `KeychainHelper`, never hardcoded or stored in files.
- Keys are loaded on `onAppear` and saved on `onChange` of the corresponding text fields.

---

## Adding a New Tool

When adding a new tool to Zoro, follow these steps:

1. **Create a new file** named `<ToolName>Tool.swift` in the `zoro/` directory.
2. **Define a struct** conforming to `Tool` from `FoundationModels`:
   ```swift
   import Foundation
   import FoundationModels

   struct MyNewTool: Tool {
       let name = "my_new_tool"
       let description = "Short description of what this tool does."

       @Generable
       struct Arguments {
           @Guide(description: "Describe this parameter")
           var paramName: String
       }

       func call(arguments: Arguments) async throws -> String {
           guard let workspaceURL = WorkspaceManager.shared.workspaceURL else {
               return "Error: No workspace directory selected."
           }
           // Implementation here
           return "Result"
       }
   }
   ```
3. **Register the tool** in `ContentView.swift` inside `getOrCreateSession()` by adding it to the `tools` array.
4. **Document the tool** in the system `instructions` string inside `getOrCreateSession()` so the LLM knows it's available.

---

## Key Frameworks & Dependencies

| Framework | Purpose |
|---|---|
| `SwiftUI` | UI layer |
| `FoundationModels` | Apple's on-device LLM framework (Tool protocol, LanguageModelSession, SystemLanguageModel) |
| `ClaudeForFoundationModels` | Anthropic Claude integration via FoundationModels API |
| `Foundation` | Core types, Process, FileManager, URLSession |
| `Security` | macOS Keychain access (SecItemAdd, SecItemCopyMatching) |
| `EventKit` | Calendar events and reminders |
| `Combine` | `@Published` / `ObservableObject` reactivity |

There are **no third-party package dependencies** (no SPM `Package.swift`). All external integrations (Tavily, Apple Notes) are done via direct HTTP requests or AppleScript.

---

## Things to Watch Out For

- **Workspace Scoping**: All file operations (read, write, list, search, patch) resolve paths *relative* to `WorkspaceManager.shared.workspaceURL`. Never use absolute paths in tool implementations.
- **Process Execution**: Terminal commands run via `/bin/zsh -c` with the workspace as the current directory. Background processes are tracked by `WorkspaceManager.activeProcesses`.
- **Search Fallback**: `SearchFilesTool` tries ripgrep first (`/opt/homebrew/bin/rg`, `/usr/local/bin/rg`, `/usr/bin/rg`), then falls back to a native Swift file enumerator. Maintain this fallback pattern.
- **AppleScript**: `AppleNotesTool` uses `/usr/bin/osascript` to drive Apple Notes. All user input injected into AppleScript strings must be escaped via `escapeForAppleScript()`.
- **No Tests Yet**: There is currently no test target or test suite. When adding tests, create a standard Xcode test target.

---

## Build & Run

- Open `zoro.xcodeproj` in Xcode.
- Select the `zoro` scheme and a macOS destination.
- Build and run (`⌘R`).
- On first launch, select a workspace folder and configure a model backend in the settings panel.

---

## iMessage Integration & Security Policy

### Overview
Zoro supports a native, zero-dependency iMessage listener that allows remote command execution and notification dispatch using macOS native APIs:
- **Outgoing Messages:** Utilizes `IMessageTool.swift` which drives the native `Messages.app` using AppleScript via `/usr/bin/osascript`.
- **Incoming Messages:** Utilizes `IMessageListener.swift` which opens `~/Library/Messages/chat.db` in read-only mode using macOS's built-in `SQLite3` bindings. Write events are monitored efficiently in real-time using a GCD `DispatchSource` file watcher.

### Security Controls
1. **Full Disk Access:** Accessing `chat.db` requires Full Disk Access enabled in macOS System Settings for the parent target (Xcode/Zoro). If not granted, the app surfaces a clear diagnostic warning.
2. **Strict Sender Whitelist:** Incoming messages are compared against a comma-separated list of whitelisted phone numbers/emails stored in `UserDefaults`. Unlisted senders are silently ignored.
3. **Passcode Verification:** If a passcode is stored in the Keychain, it must be prefixed to any command (e.g., `Zoro: [Passcode] [Command]`). Incorrect passcodes block execution.
4. **Rate Limiting:** Remote execution is capped at a maximum of 5 commands per minute. This protects against recursive loops (infinite messaging echoes) and runaway LLM billing.

### Code Constraints
- **Zero-Dependency Policy:** Do not install or require external communication CLIs (like `imsg`), Node, or Python bridges. All parsing (including binary plist/attributedBody decoding) must be done natively in Swift.
- **Read-Only Database Connections:** Always use `SQLITE_OPEN_READONLY` when opening `chat.db` to prevent locks and guarantee database integrity.

