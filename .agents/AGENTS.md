# Zoro — Project Rules for AI Agents

## Project Overview

Zoro is a native **macOS SwiftUI application** that serves as an AI-powered personal assistant with tool-calling capabilities. It uses Apple's `FoundationModels` framework to interface with on-device Apple Intelligence, Apple Private Cloud Compute, Anthropic Claude (via `ClaudeForFoundationModels`), Google Gemini, OpenAI, and Codex (ChatGPT subscription). The assistant can read/write files, run terminal commands, manage calendar events and reminders, search the web, and interact with Apple Notes — scoped to an optional workspace folder (file/shell tools) or native integrations (Notes, Calendar, Mail). Multi-account mail (Gmail OAuth + IMAP) is wired via `manage_mail` on the General agent (see Mail section).

- **Platform**: macOS 27.0+
- **Language**: Swift 5 (uses modern Swift concurrency: `async/await`, `Task`, `CheckedContinuation`)
- **UI Framework**: SwiftUI (AppKit is used only for `NSOpenPanel` and `NSColor` system colors)
- **Bundle Identifier**: `uditagarwal.zoro`

---

## Architecture

### Product shape (grill-me decisions)

- **Briefing-first home:** Dashboard with yesterday recap and today suggestions; slim composer at bottom. Not chat-first.
- **Menu bar primary:** Dock hidden by default (Settings toggle); login item on by default. Background briefing refresh while the app runs.
- **Four agents, one per thread:** General (default), Research, Planner, Teach. Pick at chat creation or General suggests handoff. No mid-chat switching in v1.
- **Memory:** Hybrid editable profile file + conservative auto-extraction. Silent save with "memory updated" notice; review, edit, and delete in Settings Memory panel (undo list not implemented).
- **Models:** Default → user-selected backend (Apple Intelligence default). Research/Planner/Teach → OpenAI when OpenAI key exists; Apple Intelligence until then. Backends: Apple Intelligence, PCC, OpenAI, Codex (ChatGPT subscription), Claude, Gemini.
- **iMessage:** Each inbound `zoro:` command → new conversation. Format: `zoro: [passcode ]research:|plan:|teach: <command>` (passcode optional). Thread continuation deferred Phase 2.
- **See also:** `docs/PRODUCT.md`, `docs/DESIGN.md`

### High-Level Structure

```
zoro/
├── App/
│   ├── zoroApp.swift        # @main: WindowGroup (AppShell), MenuBarExtra, Settings scene
│   └── AppDelegate.swift    # Dock visibility, login item, briefing background refresh
├── Views/
│   ├── AppShell.swift       # NavigationSplitView: sidebar + briefing home or chat
│   ├── BriefingHomeView.swift
│   ├── ChatView.swift
│   ├── ConversationSidebarView.swift
│   ├── ComposerView.swift
│   ├── SettingsView.swift   # Native Settings scene (General + Memory tabs)
│   └── ...
├── Services/
│   ├── AgentRunner.swift    # LLM sessions, tool sets, streaming, context compression
│   ├── ConversationStore.swift
│   ├── BriefingService.swift
│   ├── ProfileStore.swift
│   ├── AgentPrompts.swift
│   └── ...
├── Models/                  # Conversation, StoredMessage, AgentType
├── Tools/                   # Tool protocol implementations + SecurityPolicy
├── Integrations/
│   ├── Gmail/               # OAuth, REST client (wrapped by MailProvider)
│   ├── Mail/                # Multi-account MailManager, manage_mail tool, auditor
│   └── IMessage/            # Send tool + SQLite listener
├── LanguageModels/          # OpenAI, Gemini, Codex backends and auth helpers
├── Support/
│   ├── WorkspaceManager.swift  # Runtime state (workspace, todos, processes, execution context)
│   └── KeychainHelper.swift      # macOS Keychain wrapper for API keys / OAuth tokens
└── Assets.xcassets
```

### Key Patterns

1. **NavigationSplitView shell**: `AppShell` shows `BriefingHomeView` when no thread is selected and `ChatView` when a conversation is open. Settings live in the native Settings scene (`SettingsView`), not inline in the main window.

2. **AgentRunner orchestration**: `AgentRunner.shared` is the central orchestrator. It creates per-conversation `LanguageModelSession` instances, selects model backend and tools per agent type, streams responses into `ConversationStore`, and handles context compression on overflow.

3. **WorkspaceManager runtime state**: `WorkspaceManager.shared` holds workspace URL, active processes, todos, research steps, clarify continuations, and execution context (local vs iMessage). Session invalidation delegates to `AgentRunner.shared.invalidateAllSessions()`.

4. **ConversationStore persistence**: Threads persist to `~/Library/Application Support/Zoro/conversations.json`. Messages survive app restarts.

5. **Tool Protocol**: Each tool is a `struct` conforming to the `Tool` protocol from `FoundationModels`. Every tool follows the same pattern:
   - A `name` constant (the tool identifier used by the LLM)
   - A `description` constant (human-readable purpose)
   - A nested `@Generable struct Arguments` with `@Guide` annotations on each field
   - A `func call(arguments:) async throws -> String` implementation

6. **Tool registration**: Tools are registered in `AgentRunner.tools(for:)` per agent type. iMessage remote restrictions are enforced separately via `SecurityPolicy.isToolPermitted()`.

7. **Lazy session creation**: Sessions are created lazily in `AgentRunner.getOrCreateSession(conversationID:agentType:modelType:)` and reset on model or config changes.

8. **Streaming responses**: `AgentRunner.sendMessage()` calls `activeSession.streamResponse(to:)` and updates `ConversationStore` incrementally.

### Request lifecycle

```
User input (BriefingHomeView / ChatView / IMessageListener)
  → AgentRunner.sendMessage()
    → ConversationStore.appendMessage()
    → getOrCreateSession() with AgentPrompts + agent-specific tools + model backend
    → LanguageModelSession.streamResponse()
    → ConversationStore.updateLastMessageContent() (streaming)
    → MemoryExtractor.processConversation()
```

### Agent tool matrix

Tools registered in `AgentRunner.tools(for:)` (names are the tool `name` constants):

| Agent | Tools |
|---|---|
| **General** (`default`) | `run_terminal_command`, `get_process_status`, `list_directory`, `read_file`, `write_file`, `patch`, `search_files`, `current_time`, `clarify`, `todo`, `manage_calendar_and_reminders`, `manage_apple_notes`, `tavily_search`, `send_imessage`, `update_user_memory`, `manage_mail` |
| **Research** | `tavily_search`, `manage_apple_notes`, `current_time`, `clarify`, `todo`, `update_user_memory`, `read_file`, `search_files` |
| **Planner** | `manage_calendar_and_reminders`, `propose_calendar_events`, `current_time`, `clarify`, `todo`, `update_user_memory`, `manage_apple_notes` |
| **Teach** | `update_tutoring_progress`, `update_user_memory`, `clarify`, `manage_apple_notes`, `current_time` |

System instructions for each agent live in `AgentPrompts.swift`. Mail is exposed via `MailTool` (`manage_mail`) on the General agent; legacy `GmailTool` (`manage_gmail`) remains in the repo but is not registered.

### Persistence

All on-disk data lives under `~/Library/Application Support/Zoro/`:

| File | Owner | Purpose |
|---|---|---|
| `conversations.json` | `ConversationStore` | Chat threads and messages |
| `profile.json` | `ProfileStore` | Structured memory facts and freeform notes |
| `profile.md` | `ProfileStore` | Human-readable mirror of profile (also used for migration) |

Keychain (via `KeychainHelper`): `anthropic_api_key`, `gemini_api_key`, `openai_api_key`, `tavily_api_key`, `imessage_passcode`, Gmail OAuth tokens, Codex refresh token.

UserDefaults (selected keys): `selected_model_type`, `codex_model_name`, `hide_dock_icon`, `imessage_listener_enabled`, `imessage_sender_whitelist`, `briefing_refresh_interval_hours` (default 3).

### Settings (`SettingsView`)

Native Settings scene with two tabs:

**General**
- **Model** — backend picker (Apple Intelligence, PCC, Codex, Claude, Gemini, OpenAI); conditional API key fields; Codex sign-in / CLI import / device code; Tavily key; availability status
- **Briefing** — background refresh interval (2 / 3 / 4 hours)
- **Appearance** — hide Dock icon; launch at login
- **Workspace** — optional folder attach for file/shell tools
- **iMessage** — listener toggle, sender whitelist, optional passcode, Full Disk Access status

**Memory**
- Editable freeform profile notes
- Saved facts (add, edit, delete; sources: auto, manual, planner, teach)

**Mail**
- Gmail OAuth app credentials and per-account connect/disconnect
- IMAP accounts (Namecheap Private Email, iCloud presets)
- Sync all, weekly cleanup schedule


## Coding Conventions

### Naming
- **Files**: PascalCase. Tool files are named `<ToolName>Tool.swift` (e.g., `CommandLineTool.swift`, `PatchTool.swift`).
- **Types**: PascalCase for structs, classes, enums, and protocols.
- **Properties & Methods**: camelCase. Use descriptive names (e.g., `runCommandBackground`, `activeClarificationQuestion`).
- **Tool Names** (the `name` constant): snake_case strings matching what the LLM references (e.g., `"run_terminal_command"`, `"search_files"`).

### Style
- Use `// MARK: -` section headers to separate logical groups within a file (see `FileTools.swift`).
- Use Xcode's default file header comment block (`// Created by ... on ...`).
- Prefer inline comments that explain *why*, not *what*.
- Keep `import` statements minimal — only import frameworks that are directly used.

### Error Handling
- Tools return error messages as `String` values (e.g., `"Error: No workspace directory selected."`) rather than throwing. This keeps the LLM's tool loop stable.
- Use `guard let ... else { return "Error: ..." }` for early validation of required fields.
- Errors surfaced to the user in the chat include actionable tips (e.g., "Tip: Open Settings (⌘,) and configure a model backend...").

### Concurrency
- Use Swift's structured concurrency (`async/await`, `Task { }`) for all asynchronous work.
- Use `DispatchQueue.main.async` (not `@MainActor`) for publishing `@Published` property changes from background contexts in `WorkspaceManager`.
- Use `withCheckedContinuation` / `withCheckedThrowingContinuation` for bridging callback-based APIs (e.g., EventKit permissions, ClarifyTool suspension).

### Secrets Management
- API keys (Anthropic, Gemini, OpenAI, Tavily), Codex tokens, iMessage passcode, and Gmail OAuth credentials/tokens are stored in the macOS Keychain via `KeychainHelper`, never hardcoded or stored in files.
- Keys are loaded on `onAppear` and saved on `onChange` of the corresponding text fields.

---

## Adding a New Tool

When adding a new tool to Zoro, follow these steps:

1. **Create a new file** named `<ToolName>Tool.swift` in `zoro/Tools/`.
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
3. **Register the tool** in `AgentRunner.tools(for:)` for each agent type that should use it.
4. **Add iMessage permissions** in `SecurityPolicy.isToolPermitted()` if the tool should be blocked or allowed in remote sessions.
5. **Update agent instructions** in `AgentPrompts.swift` if the LLM needs explicit guidance about the new capability.

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
- **Unit tests**: The `zoroTests` target includes `Mail/*Tests`, `Gmail/GmailParsingTests`, `Codex/CodexAuthTests`, and `Codex/CodexRequestSupportTests`. Run via ⌘U in Xcode on macOS.

---

## Build & Run

- Open `zoro.xcodeproj` in Xcode.
- Select the `zoro` scheme and a macOS destination.
- Build and run (`⌘R`).
- On first launch, configure a **model backend** in Settings (⌘,). Attach a workspace folder in Settings → Workspace **only if** you need file or terminal tools; briefing and chat work without one.

---

## XcodeBuild MCP (local macOS agents)

When Cursor runs on a **macOS host with Xcode 16+**, use the project-scoped **XcodeBuildMCP** server (`.cursor/mcp.json`) and `.xcodebuildmcp/config.yaml` session defaults (`zoro` scheme, `./zoro.xcodeproj`, macOS `Debug`).

**Typical verification flow (via MCP tools):**
1. `macos build` — compile the app.
2. `macos test` — run `zoroTests` (mail ranking/cleanup/auditor, Gmail parsing, Codex auth/request tests).
3. `macos build-and-run` — build and launch the app (requires GUI session for SwiftUI).

Session defaults are preconfigured; override only if switching scheme or configuration. After editing `.xcodebuildmcp/config.yaml`, reload MCP servers in Cursor.

**Prerequisites:** Full Xcode installed (not Command Line Tools only). If `xcode-select -p` shows `/Library/Developer/CommandLineTools`, run `sudo xcode-select -s /Applications/Xcode-beta.app/Contents/Developer` (or `/Applications/Xcode.app/...` for stable Xcode). `.cursor/mcp.json` sets `DEVELOPER_DIR` to Xcode-beta so MCP builds work even before you fix `xcode-select`. Accept license if needed (`sudo xcodebuild -license accept`). Shared `zoro` scheme lives at `zoro.xcodeproj/xcshareddata/xcschemes/zoro.xcscheme`. First build needs network for SPM (`ClaudeForFoundationModels`).

**MCP tool names:** `build_macos`, `test_macos`, `build_run_macos`, `session_show_defaults` (call first each session).

---

## Cursor Cloud specific instructions

- **This project cannot be built, run, lint-checked, or tested on the Cursor Cloud agent VM.** Cloud agents run on **Linux** (Ubuntu 24.04, x86_64). Zoro is a native **macOS Xcode application** (`com.apple.product-type.application`, `MACOSX_DEPLOYMENT_TARGET = 27.0`) that imports Apple-only frameworks: `FoundationModels`, `SwiftUI`, `EventKit`, `Security` (Keychain), plus the `ClaudeForFoundationModels` SPM package. These frameworks ship only inside the macOS/Xcode SDK and do **not** exist in the Swift toolchain for Linux.
- A Swift-for-Linux toolchain (`swift` 6.x via `swiftly`) *can* be installed, but it cannot compile this app: `swiftc -typecheck` fails immediately with `no such module 'FoundationModels'` / `no such module 'SwiftUI'`. Do not waste time trying to make it build on Linux.
- There is a **`zoroTests` unit test target** (XCTest), but it only runs on macOS via Xcode. There is **no `Package.swift`**, no Makefile, and no `npm`/`pip`/CLI dev server. The only build/run path is Xcode on macOS (see "Build & Run" above).
- To actually build/run/test, a developer must use a **macOS host with Xcode 26.x+** (Apple Intelligence–capable for the on-device backend; otherwise configure a Claude or Gemini API key in Settings (⌘,), stored in the macOS Keychain). Xcode auto-resolves the `ClaudeForFoundationModels` SPM dependency on first build (network required once).
- Practical implication for cloud agents: scope work here to **code reading/editing and static reasoning**. Any verification that requires compiling or running the app must be done by the user on macOS.

---

## iMessage Integration & Security Policy

### Overview
Zoro supports a native, zero-dependency iMessage listener that allows remote command execution and notification dispatch using macOS native APIs:
- **Outgoing Messages:** `Integrations/IMessage/IMessageTool.swift` drives the native `Messages.app` using AppleScript via `/usr/bin/osascript`.
- **Incoming Messages:** `Integrations/IMessage/IMessageListener.swift` opens `~/Library/Messages/chat.db` in read-only mode using macOS's built-in `SQLite3` bindings. Write events are monitored efficiently in real-time using a GCD `DispatchSource` file watcher.

### Security Controls
1. **Full Disk Access:** Accessing `chat.db` requires Full Disk Access enabled in macOS System Settings for the parent target (Xcode/Zoro). If not granted, the app surfaces a clear diagnostic warning.
2. **Strict Sender Whitelist:** Incoming messages are compared against a comma-separated list of whitelisted phone numbers/emails stored in `UserDefaults`. Unlisted senders are silently ignored. Contacts are normalized before comparison.
3. **Optional Passcode:** Remote commands may require a passcode stored in the Keychain. If configured, the passcode must appear immediately after `zoro:` and before agent prefixes. The listener can be enabled with whitelist only (passcode labeled optional in Settings).
4. **Command Prefix:** Messages must start with `zoro:` (case-insensitive). Agent routing prefixes (`research:`, `plan:`, `teach:`) come after the optional passcode.
5. **Incoming-Only Messages:** The listener only processes incoming messages (`is_from_me = 0`) to prevent self-triggered command loops.
6. **Global Rate Limiting:** Remote execution is capped at 5 commands per minute **app-wide** (not per sender).
7. **Runtime tool restrictions:** iMessage sessions use the same `AgentRunner` tool registration as local chat. Tools in `SecurityPolicy`'s `iMessageAllowedTools` whitelist may run remotely: `list_directory`, `read_file`, `search_files`, `current_time`, `todo`, `manage_calendar_and_reminders`, `manage_apple_notes`, `tavily_search`, `send_imessage`, `manage_mail`. Other tools fail via `WorkspaceManager.toolPermissionError()` when they check permissions. `ClarifyTool` refuses to suspend on iMessage. Notes and calendar actions have additional action-level restrictions via `isNotesActionPermitted()` / `isCalendarActionPermitted()`.
8. **Workspace Path Validation:** All file tools resolve paths with `SecurityPolicy.resolveWorkspacePath()` and reject absolute paths or traversal outside the workspace root.
9. **Attachment Scoping:** iMessage attachments are only read from `~/Library/Messages/Attachments`.
10. **Outbound iMessage Restrictions:** Remote sessions may only reply to the requester who sent the command.
11. **AppleScript + HTML Escaping:** User/LLM content injected into AppleScript or Notes HTML passes through `SecurityPolicy.escapeForAppleScript()` / `SecurityPolicy.escapeHTML()`.
12. **Resource Limits:** File reads, shell output, shell timeouts, and iMessage reply length are capped in `SecurityPolicy.swift`.
13. **Keychain Hardening:** Secrets use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
14. **Gemini API Key Transport:** Gemini requests send the API key via the `x-goog-api-key` header, not the URL query string.

### Code Constraints
- **Zero-Dependency Policy:** Do not install or require external communication CLIs (like `imsg`), Node, or Python bridges. All parsing (including binary plist/attributedBody decoding) must be done natively in Swift.
- **Read-Only Database Connections:** Always use `SQLITE_OPEN_READONLY` when opening `chat.db` to prevent locks and guarantee database integrity.

---

## Mail Integration (Multi-Account)

### Overview
Mail is a first-class integration across Gmail (OAuth) and IMAP (Namecheap Private Email, iCloud). Design goals: unified briefing inbox, complete fetches with explicit completeness flags, and anti-hallucination guardrails.

**Implementation status:** Wired — `manage_mail` on General agent, Settings **Mail** tab, briefing inbox section, `MailReadAuditor` in `AgentRunner` response pipeline.

| File | Purpose |
|---|---|
| `Integrations/Mail/MailManager.swift` | Unified sync, priority ranking, session read tracking, `contextualInstructions()` |
| `Integrations/Mail/MailTool.swift` | LLM-facing `manage_mail` tool |
| `Integrations/Mail/MailReadAuditor.swift` | Blocks unsourced email summaries in chat |
| `Integrations/Mail/MailAccountStore.swift` | Multi-account registry, Keychain schema, legacy Gmail migration |
| `Integrations/Mail/GmailMailProvider.swift` | Gmail `MailProvider` adapter |
| `Integrations/Mail/IMAP/IMAPMailProvider.swift` | IMAP provider (MailCore2) |
| `Integrations/Gmail/GmailAuthManager.swift` | Multi-account OAuth 2.0 desktop flow |
| `Integrations/Gmail/GmailService.swift` | Gmail REST client (per `accountId`), pagination, fetch reports |
| `Views/Mail/SettingsMailAccountsSection.swift` | Settings Mail tab (add Gmail/IMAP, disconnect, sync) |

Setup guides: `reference/mail-setup.md`, `reference/gmail-setup.md`

### Tool actions (`manage_mail`)
- `get_status` — connected accounts, unread counts, sync health
- `list_unread` / `search` — **index only** (metadata + snippets)
- `read_message` — **full body** with `body_complete` flag
- `archive_message`, `mark_read`
- `create_draft`, `send_email`, `reply_to_message` — draft-only; user confirms via `MailSendConfirmPanel`

### Hard read enforcement
- `MailReadAuditor` blocks assistant responses that summarize email without a `read_message` call in the same turn
- Wired in `AgentRunner.sendMessage()` after each assistant response
- `MailManager.contextualInstructions()` injected in `AgentRunner.getOrCreateSession()` when accounts are connected

### Anti-hallucination design
1. Every tool response includes a `=== MAIL FETCH REPORT ===` block with `fetch_complete`, `items_fetched`, and warnings.
2. Search/list results are explicitly marked INDEX ONLY — agent must call `read_message` before summarizing.
3. Connect/disconnect calls `WorkspaceManager.invalidateSessionsForConfigChange()` so new sessions pick up mail rules.

### Security & limits (`SecurityPolicy.swift`)
- `manage_mail` in iMessage allowed tools; send/archive denied remotely via `isMailActionPermitted()`
- Gmail limits preserved: page size 25, max 250 messages/operation, batch read 20, body 1 MB, 5 retries

### OAuth redirect URI
`http://127.0.0.1:8765/` — local callback server in `OAuthCallbackServer`

### Legacy Gmail code
`GmailTool` (`manage_gmail`), `GmailManager`, and `GmailReadAuditor` remain for reference; production path uses `MailTool` / `MailManager` / `MailReadAuditor`.

### Test target
- `zoroTests` — run with ⌘U in Xcode; includes `Mail/MailPriorityRankerTests`, `Mail/CleanupHeuristicsTests`, `Mail/EmailCalendarDetectorTests`, `Mail/MailReadAuditorTests`, `Gmail/GmailParsingTests`, `Codex/CodexAuthTests`, and `Codex/CodexRequestSupportTests`

