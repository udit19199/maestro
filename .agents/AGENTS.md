# Zoro — Project Rules for AI Agents

## Project Overview

Zoro is a native **macOS SwiftUI application** that serves as an AI-powered personal assistant with tool-calling capabilities. It uses Apple's `FoundationModels` framework to interface with on-device Apple Intelligence, Apple Private Cloud Compute, Anthropic Claude (via `ClaudeForFoundationModels`), and Google Gemini. The assistant can read/write files, run terminal commands, manage calendar events and reminders, search the web, interact with Apple Notes, and access Gmail — all scoped to a user-selected workspace directory (file/shell tools) or connected accounts (Gmail, Notes, Calendar).

- **Platform**: macOS 27.0+
- **Language**: Swift 5 (uses modern Swift concurrency: `async/await`, `Task`, `CheckedContinuation`)
- **UI Framework**: SwiftUI (AppKit is used only for `NSOpenPanel` and `NSColor` system colors)
- **Bundle Identifier**: `uditagarwal.zoro`

---

## Development Workflow (Linear — Required)

**Before making any changes** to this repository — code, tests, docs, or configuration — you must have an open Linear issue in the [Zoro project](https://linear.app/udit19199/project/zoro-75b62c67c4d1).

1. **Find or create an issue** — Search existing backlog items first. If nothing matches, create a new issue in the Zoro project with a clear title, acceptance criteria, and appropriate labels (`area:*`, `type:*`).
2. **Start work** — Move the issue to **In Progress** before editing files.
3. **Link your work** — Reference the Linear issue ID (e.g. `UDI-123`) in commit messages and pull request descriptions.
4. **Finish** — Move the issue to **Done** when the change is merged or shipped.

Do not begin implementation without a tracked Linear issue. Question-only or read-only exploration does not require an issue; any change that modifies the repo does.

Feature inventory, labels, milestones, and catalog refs (`ZORO-XXX`): `reference/linear-setup.md` · Issue seed data: `scripts/linear-issues.json`

---

## Architecture

### High-Level Structure

```
zoro/
├── zoroApp.swift            # @main App entry point
├── ContentView.swift        # Single-view architecture: chat UI, settings, session management
├── WorkspaceManager.swift   # Singleton state manager (workspace, processes, todos, research, sessions)
├── KeychainHelper.swift     # macOS Keychain wrapper for API key / OAuth token storage
├── GmailAuthManager.swift   # Gmail OAuth 2.0 desktop flow
├── GmailService.swift       # Gmail REST API client (pagination, fetch reports)
├── GmailManager.swift       # Gmail UI state + agent context injection
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
- API keys (Anthropic, Gemini, Tavily) and Gmail OAuth credentials/tokens are stored in the macOS Keychain via `KeychainHelper`, never hardcoded or stored in files.
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
3. **Register the tool** in `WorkspaceManager.swift` inside both `localTools` and (if appropriate) `iMessageTools` arrays.
4. **Document the tool** in the `localInstructions` / `iMessageInstructions` strings in `WorkspaceManager.swift` so the LLM knows it's available.

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

There is **one SPM dependency**: `ClaudeForFoundationModels`. Gmail, Tavily, Apple Notes, and iMessage integrations use direct HTTP (`URLSession`) or AppleScript — no Google SDK.

---

## Things to Watch Out For

- **Workspace Scoping**: All file operations (read, write, list, search, patch) resolve paths via `SecurityPolicy.resolveWorkspacePath()` relative to `WorkspaceManager.shared.workspaceURL`. Absolute paths and workspace escapes are rejected.
- **Process Execution**: Terminal commands run via `/bin/zsh -c` with the workspace as the current directory. Background processes are tracked by `WorkspaceManager.activeProcesses`.
- **Search Fallback**: `SearchFilesTool` tries ripgrep first (`/opt/homebrew/bin/rg`, `/usr/local/bin/rg`, `/usr/bin/rg`), then falls back to a native Swift file enumerator. Maintain this fallback pattern.
- **AppleScript**: `AppleNotesTool` and `IMessageTool` use `/usr/bin/osascript`. All user input injected into AppleScript strings must be escaped via `SecurityPolicy.escapeForAppleScript()`.
- **Tests**: The `zoroTests` unit test target includes Gmail parsing tests (`GmailParsingTests.swift`). Run via ⌘U in Xcode.

---

## Build & Run

- Open `zoro.xcodeproj` in Xcode.
- Select the `zoro` scheme and a macOS destination.
- Build and run (`⌘R`).
- On first launch, select a workspace folder and configure a model backend in the settings panel.

---

## Cursor Cloud specific instructions

- **This project cannot be built, run, lint-checked, or tested on the Cursor Cloud agent VM.** Cloud agents run on **Linux** (Ubuntu 24.04, x86_64). Zoro is a native **macOS Xcode application** (`com.apple.product-type.application`, `MACOSX_DEPLOYMENT_TARGET = 27.0`) that imports Apple-only frameworks: `FoundationModels`, `SwiftUI`, `EventKit`, `Security` (Keychain), plus the `ClaudeForFoundationModels` SPM package. These frameworks ship only inside the macOS/Xcode SDK and do **not** exist in the Swift toolchain for Linux.
- A Swift-for-Linux toolchain (`swift` 6.x via `swiftly`) *can* be installed, but it cannot compile this app: `swiftc -typecheck` fails immediately with `no such module 'FoundationModels'` / `no such module 'SwiftUI'`. Do not waste time trying to make it build on Linux.
- There is a **`zoroTests`** unit test target (Gmail parsing tests only today), but **no `Package.swift`**, no Makefile, and no `npm`/`pip`/CLI dev server. The only build/run path is Xcode on macOS (see "Build & Run" above).
- To actually build/run/test, a developer must use a **macOS host with Xcode 26.x+** (Apple Intelligence–capable for the on-device backend; otherwise configure a Claude or Gemini API key under the in-app Settings gear, which are stored in the macOS Keychain). Xcode auto-resolves the `ClaudeForFoundationModels` SPM dependency on first build (network required once).
- Practical implication for cloud agents: scope work here to **code reading/editing and static reasoning**. Any verification that requires compiling or running the app must be done by the user on macOS.

---

## iMessage Integration & Security Policy

### Overview
Zoro supports a native, zero-dependency iMessage listener that allows remote command execution and notification dispatch using macOS native APIs:
- **Outgoing Messages:** Utilizes `IMessageTool.swift` which drives the native `Messages.app` using AppleScript via `/usr/bin/osascript`.
- **Incoming Messages:** Utilizes `IMessageListener.swift` which opens `~/Library/Messages/chat.db` in read-only mode using macOS's built-in `SQLite3` bindings. Write events are monitored efficiently in real-time using a GCD `DispatchSource` file watcher.

### Security Controls
1. **Full Disk Access:** Accessing `chat.db` requires Full Disk Access enabled in macOS System Settings for the parent target (Xcode/Zoro). If not granted, the app surfaces a clear diagnostic warning.
2. **Strict Sender Whitelist:** Incoming messages are compared against a comma-separated list of whitelisted phone numbers/emails stored in `UserDefaults`. Unlisted senders are silently ignored. Contacts are normalized before comparison.
3. **Required Passcode:** Remote iMessage commands require a passcode stored in the Keychain. The listener cannot be enabled without both a passcode and at least one whitelisted sender.
4. **Incoming-Only Messages:** The listener only processes incoming messages (`is_from_me = 0`) to prevent self-triggered command loops.
5. **Per-Sender Rate Limiting:** Remote execution is capped at 5 commands per minute per sender.
6. **Restricted Remote Tool Set:** iMessage sessions use a separate LLM session with a reduced tool set. Shell commands, file writes, patches, process inspection, and clarifying questions are blocked remotely.
7. **Workspace Path Validation:** All file tools resolve paths with `SecurityPolicy.resolveWorkspacePath()` and reject absolute paths or traversal outside the workspace root.
8. **Attachment Scoping:** iMessage attachments are only read from `~/Library/Messages/Attachments`.
9. **Outbound iMessage Restrictions:** Remote sessions may only reply to the requester who sent the command.
10. **AppleScript + HTML Escaping:** User/LLM content injected into AppleScript or Notes HTML passes through `SecurityPolicy.escapeForAppleScript()` / `SecurityPolicy.escapeHTML()`.
11. **Resource Limits:** File reads, shell output, shell timeouts, and iMessage reply length are capped in `SecurityPolicy.swift`.
12. **Keychain Hardening:** Secrets use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
13. **Gemini API Key Transport:** Gemini requests send the API key via the `x-goog-api-key` header, not the URL query string.

### Code Constraints
- **Zero-Dependency Policy:** Do not install or require external communication CLIs (like `imsg`), Node, or Python bridges. All parsing (including binary plist/attributedBody decoding) must be done natively in Swift.
- **Read-Only Database Connections:** Always use `SQLITE_OPEN_READONLY` when opening `chat.db` to prevent locks and guarantee database integrity.

---

## Gmail Integration (First-Class)

### Overview
Gmail is a first-class integration — not a secondary tool. The user relies on it heavily. Design goals: complete fetches, explicit completeness flags, and anti-hallucination guardrails.

| File | Purpose |
|---|---|
| `GmailAuthManager.swift` | OAuth 2.0 desktop flow; tokens in Keychain |
| `GmailService.swift` | REST client; pagination; `GmailFetchReport` on every response |
| `GmailManager.swift` | Inbox preview, unread count, activity log, `contextualInstructions()` |
| `GmailTool.swift` | LLM-facing `manage_gmail` tool |

Setup guide: `reference/gmail-setup.md`

### Tool actions (`manage_gmail`)
- `get_status` — account email, unread inbox, totals
- `list_messages` / `search_messages` — **index only**; `fetchAll` defaults true (cap 250)
- `read_message` / `read_messages` / `read_thread` — **full bodies** with `body_complete` flag
- `read_attachment` — text and PDF attachments (PDFKit)
- `mark_read`, `archive_message`, `star_message`, `unstar_message`, `modify_labels`, `list_labels`
- `create_draft`, `reply_to_thread`, `send_email`, `trash_message`

### Hard read enforcement
- `GmailReadAuditor` blocks assistant responses that summarize email without a `read_*` call in the same turn
- Applied in `ContentView` (local chat) and `IMessageListener` (remote)
- Every tool response appends `session_messages_fully_read`

### Anti-hallucination design
1. Every tool response includes a `=== GMAIL FETCH REPORT ===` block with `fetch_complete`, `items_fetched`, and warnings.
2. Search/list results are explicitly marked INDEX ONLY — agent must call read_* before summarizing.
3. When Gmail is connected, `WorkspaceManager.makeSession()` appends `GmailManager.contextualInstructions()` to system instructions.
4. Connect/disconnect calls `WorkspaceManager.invalidateSessionsForConfigChange()` so new sessions pick up Gmail rules.

### Security & limits (`SecurityPolicy.swift`)
- `gmailPageSize` = 25, `maxGmailMessagesPerOperation` = 250, `maxGmailBatchRead` = 20
- `maxGmailBodyBytes` = 1 MB, `gmailMaxRetries` = 5 (429/5xx backoff)
- iMessage remote: read/search allowed; send/trash denied via `isGmailActionPermitted()`

### UI (`ContentView.swift`)
- Header badge when connected (email, unread, sync, refresh)
- Inbox preview panel (latest 5 messages)
- Gmail activity log during agent runs

### OAuth redirect URI
`http://127.0.0.1:8765/` — local callback server in `OAuthCallbackServer`

### Known gaps (not yet implemented)
- Image attachment OCR — text/PDF only today
- Background push via Gmail Pub/Sub (requires public HTTPS endpoint)

### Test target
- `zoroTests` — run with ⌘U in Xcode; includes `GmailParsingTests` for offline parsing coverage

### Issue tracking (Linear)
- **Mandatory before changes** — see [Development Workflow (Linear — Required)](#development-workflow-linear--required) above.
- Feature inventory and Linear setup guide: `reference/linear-setup.md`
- Live project: [Zoro on Linear](https://linear.app/udit19199/project/zoro-75b62c67c4d1) (107 catalogued items: 95 shipped, 12 backlog)

