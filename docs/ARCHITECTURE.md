# Architecture

Owner: Staff · Maestro lead. Written 15 Nov 2026 from `main` at `3444e9b`. "Measured" means a number from a run. "Suspected" means a reading of the code that build must still measure.

## 1. How the app works today

### Processes

```
Maestro.app (SwiftUI, one process, everything on the main actor)
 ├─ pi --mode rpc   one per (chat × bot); a group of 6 bots = 6 processes
 │    └─ loads maestro-pi.ts (-e): message_bot, gmail_*, calendar_*, MCP approval gate
 │         └─ new TLS connection to imap.gmail.com / smtp.gmail.com on every mail tool call
 ├─ pi --mode rpc   short-lived, one per Settings request (providers, models, mail check)
 └─ pi / npx        MCP connect (Settings > MCP servers)
Relay  127.0.0.1:8317  (separate app; every model call goes through it)
```

- A chat's pi process starts on its first message and stays alive until that chat is deleted, its bot or members change, or the app quits. Nothing stops idle processes (`maestro/Pi/PiSessions.swift:93-116`, `:48-53`).
- Swift talks to pi over stdin/stdout, one JSON object per line (`maestro/Pi/PiRPC.swift:101-137`, wire shapes in `maestro/Pi/PiProtocol.swift`).

### From message to model to screen

1. `ComposerView` → `PiSessions.sendMessage` (`PiSessions.swift:66`). For a group, `mentioned(in:)` picks the speakers by @name, and `unseen(by:)` rebuilds the lines that bot has not seen yet as one prompt (`:148-158`).
2. Swift appends the user message and an empty assistant message with status `streaming` to `ConversationStore` (`:79-91`), then starts or reuses the pi process and writes a `prompt` command.
3. pi sends the prompt to Relay, runs tools, and streams `message_update` events. The wire carries only the new text in each event, so the stream stays linear (pi `docs/json.md` §"Reconstruct streaming messages").
4. `PiRPC.receive` splits the output into lines and JSON-decodes each one on the main actor. One `Task` hops to the main actor per stdout chunk (`PiRPC.swift:101-108`, `:124-137`).
5. For each `text_delta`: `run.text += delta` → `ConversationStore.updateMessage` (`PiSessions.swift:232-238`, `:220-224`). That function copies the whole `conversations` array, writes back the changed message, and publishes the copy. It also restarts a 500 ms save timer (`ConversationStore.swift:150-164`, `:115-123`).
6. SwiftUI: `ConversationStore` is one `ObservableObject`, so every view that observes it re-renders on each change. That includes `AppShell`, the sidebar (which regroups every chat by day) and `ChatView`, which rebuilds the `ForEach` over all messages and calls `scrollTo` (`ChatView.swift:71-82`).
7. `agent_settled` → Swift asks for `get_last_assistant_text` → `finish` → `persistNow()` writes the whole history of every chat as pretty-printed JSON with sorted keys, on the main thread (`PiSessions.swift:243-253`, `:163-174`; `ConversationStore.swift:125-135`).
8. Side channels are carried inside pi's extension UI requests:
   - **Approval:** `confirm` → an approval card in the chat → `extension_ui_response`.
   - **Hand-off:** `message_bot` makes the extension post a `notify` whose text is JSON `{handoff}`. Swift reads it and starts a turn in the target chat, at most 4 hops (`PiSessions.swift:191-219`).
   - **Calendar:** the extension sends an `input` request titled `maestro.calendar` with the request as JSON. Swift runs it on EventKit and replies with the result as JSON (`maestro/Pi/MacCalendar.swift`).

### Where state lives

| State | Where | Who writes it |
|---|---|---|
| Chats and messages shown on screen | `~/Library/Application Support/Maestro/conversations.json` (one file, all chats) | Swift |
| Model context (history, compaction, tool results) | `…/Maestro/pi/agent/sessions/<chat>[-<bot>]/` (pi JSONL) | pi |
| Bots | `…/Maestro/bots/<id>/definition.json` | Swift |
| Providers, models, MCP config | `…/Maestro/pi/agent/{auth,models,settings}.json` | pi / Settings |
| Gmail app password | `…/Maestro/pi/agent/mail.json` (mode 600) | Settings |
| Live run state (streaming text, approvals, queued turns) | memory only, `PiSessions` | Swift |
| Calendar | macOS EventKit (no grant yet) | EventKit |

Each conversation is stored twice, and the two copies can disagree: Swift's display copy and pi's model copy. Mail has no local cache. Every search reads Gmail again.

## 2. Where time and memory likely go

Measured on 15 Nov 2026 (M-series Mac, Node 24.19, pi 1.2.0). Method: start `pi --mode rpc --no-session --no-mcp -e maestro-pi.ts` with Maestro's environment, send `get_available_models`, time until the response, read RSS 1 s later, 3 runs (`/tmp/maestro-lead/probe.py`).

| What | Number |
|---|---|
| pi start → first response, cold | 463 ms |
| pi start → first response, warm | 207–214 ms |
| pi memory per process, idle, no MCP | 116 MB (167 MB first run) |

What follows from the numbers and the code (suspected until build measures it):

1. **Memory grows with the number of chats.** About 116 MB for each chat × bot that has been used since launch, and none of it is released. With 3 one-bot chats, pi alone uses about 350 MB. One 6-bot group adds about 700 MB. An MCP server (Notion) adds its own process for each pi process. This is probably the largest memory cost, and it does not depend on the shell language.
2. **Every streamed word does work proportional to all history.** For each token, the app copies the conversations array, re-renders the sidebar and the chat, and runs `scrollTo`. Each message is one `Text`, so a long reply is laid out again on every token. This probably causes frame drops while streaming long chats.
3. **Saving rewrites everything.** Every finished turn (and every 500 ms pause while streaming) writes the whole pretty-printed JSON of all chats on the main thread. The cost grows with total history.
4. **Delay before the first word.** A new chat waits about 210–460 ms for pi to start, plus extension load, before the prompt goes to Relay. Hand-offs into a chat that is not running yet pay the same.
5. **Mail latency.** Each `gmail_*` call opens TLS, logs in, and runs `LIST` before it does any work. A search followed by reading 5 messages makes several round trips to Gmail with no reuse. No local copy exists, so "mail sync time" today means "time per tool call".
6. **The stream is not the problem.** pi sends only deltas on the wire. Relay's own time to first token is outside this repo and should be measured separately.

Build's baseline should measure: cold start of the app, time from Send to the first word on screen, memory at idle and with 3 chats (app plus all pi children), CPU at idle, frame time while streaming a 2,000-word reply into a chat with 200 messages, and time per mail tool call.

## 3. Target architectures

Every option keeps pi. pi runs on Node, so a Node runtime is always present whatever the shell language is. The real choices are how many Node processes there are, and who owns orchestration and storage.

### A. Keep the shape, fix the hot paths (Swift shell, pi per chat)

- Stream into a per-run buffer and publish at most once per frame. Give each chat its own observable object (`@Observable`), so streaming does not re-render the sidebar. Split long replies into blocks so only the last block is laid out again.
- Store chats as one append-only file each (or SQLite), written off the main thread.
- Stop pi processes after N minutes idle. A restart costs about 210 ms because pi reloads its session from disk.
- Keep IMAP open for a short time in each pi process.

Trade-offs: the smallest change and the lowest risk, and Swift stays. Memory still grows with the number of active chats. Two copies of the history remain. Each pi process still has its own mail connection and MCP processes.

### B. One core process: pi SDK in Node, thin shell (recommended direction)

- One long-lived `maestro-core` Node process embeds pi through its SDK (`createAgentSession`; one `AgentSession` per chat × bot, all in one process; pi `docs/sdk.md`). It owns orchestration (routing, @mentions, hand-offs, hop limit, approvals), one shared IMAP connection with a local mail cache, MCP clients shared by all sessions, and storage. pi's session JSONL is the one record of history, and the UI reads from it.
- The shell becomes a view. It connects to the core over one socket or stdio stream that carries events for all chats. It owns windows, approval cards, EventKit (calendar access is granted to the app) and notifications.
- Expected: about 120 MB for one Node process plus a few MB per session, instead of 116 MB per session. New chats start in milliseconds instead of 210–460 ms. Hand-offs become function calls. The shell language no longer matters for logic, so Swift, Rust or anything else is only a UI choice.

Trade-offs: hand-offs and group routing move from Swift to TypeScript (a rewrite of about 600 lines). The SDK does not load MCP, codemode or tool_search by default; they must be added explicitly (`docs/sdk.md` §codemode-mcp). One crash in the core stops every chat, so the shell must restart it. pi runs inside our process, so a pi upgrade can break the core at build time instead of at the RPC boundary.

### C. Rust core plus pi RPC processes, native or webview shell

- A Rust process owns orchestration, storage (SQLite) and mail (async IMAP with a cache), and starts pi RPC processes as Swift does today. The shell is Tauri (webview) or a native frontend.

Trade-offs: Rust makes the parts that are already cheap faster (routing, JSON, storage). It keeps the most expensive part: one Node process per session. It is the largest rewrite, and a webview shell probably uses more memory than SwiftUI. It is worth choosing only if the stack thread measures a large UI-side win that Swift cannot match.

### Current lean, not a decision

B's core with whatever shell the stack thread measures as best. Do A's UI fixes (frame-rate publishing, per-chat observation, block layout) in any shell. The decision, with an independent Opus critique, goes in §4 when the stack recommendation lands.

## 4. Decision

Pending: waiting for the stack thread's measured recommendation.
