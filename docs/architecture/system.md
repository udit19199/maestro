# System

## 1. Processes

```
Maestro.app (SwiftUI, menu bar app, login item)
 │  owns: windows, menu bar, Keychain, EventKit, Messages (iMessage), notifications
 │
 │  stdin/stdout, NDJSON JSON-RPC 2.0 (protocol.md)
 ▼
maestro-core (Node 24, bundled; one process)
 │  owns: SQLite store, routing, runs, policy, proposals, ledger, memory,
 │        routines, channels, mail sync, MCP pool, bot file loading
 │
 ├─ pi SDK: one AgentSession per (thread, bot, episode), created on demand
 ├─ MCP servers: one client per configured server, shared by all sessions
 └─ HTTPS: model providers (Relay at 127.0.0.1:8317 or any pi provider), Gmail API, Google OAuth
```

- The app is the parent of the core. Closing the window does not quit the app; it stays in the menu bar so routines and channels keep running. Quitting the app stops the core.
- The core never touches the screen, Keychain, EventKit or Messages directly. It asks the shell through **host requests** (protocol.md §5). This keeps every macOS permission on one bundle, `Maestro.app`.
- There is one core per user account. A second app launch focuses the first one.

## 2. Components inside the core

```
            ┌────────────── Protocol server (stdio) ──────────────┐
            │  commands in, events out, host requests out          │
            └───────┬───────────────────────────────▲──────────────┘
                    │                               │ events (after commit)
┌───────────────┐ ┌─▼──────────┐ ┌──────────────┐ ┌─┴────────────┐
│ Workspace     │ │ Router     │ │ Run manager  │ │ Event bus    │
│ loader        │ │ mentions,  │ │ queue, runs, │ │ batching,    │
│ bots, skills, │ │ hand-offs, │ │ sessions,    │ │ fan-out      │
│ routines      │ │ channels   │ │ episodes     │ └──────────────┘
└──────┬────────┘ └─────┬──────┘ └──────┬───────┘
       │                │               │ tool calls
       │          ┌─────▼───────────────▼─────┐   ┌──────────────┐
       │          │ Action gate               │──►│ Proposal     │
       │          │ effect table, policy      │   │ queue, holds │
       │          └─────┬─────────────────────┘   └──────┬───────┘
       │                │ allowed                        │ approved
       │          ┌─────▼────────────────────────────────▼───────┐
       │          │ Connectors: mail, calendar, messages, MCP    │
       │          └──────────────────────────────────────────────┘
┌──────▼────────────────────────────────────────────────────────────┐
│ Store (SQLite, single writer)  ·  pi session JSONL files          │
└───────────────────────────────────────────────────────────────────┘
  Scheduler (routines, holds, idle disposal, mail polling) feeds the Router.
  Context builder (memory, ledger, thread header) feeds the Run manager.
```

| Component | Owns | Does not |
|---|---|---|
| Protocol server | Framing, validation of every incoming message against the schema, request ids, host requests | Business logic |
| Workspace loader | Reading and validating `.agents/` files, watching them, reporting errors per file | Writing bot files (only the shell's editor and export do) |
| Router | Turning an inbound message (desktop, channel, routine, hand-off) into run requests: which bots, which thread, which episode | Talking to pi |
| Run manager | Per-session queue, starting and stopping runs, creating and disposing sessions, mapping pi events to Maestro events | Deciding policy |
| Context builder | The per-run blocks: thread header, memory, ledger, episode carry-over (context.md) | Storing memory |
| Action gate | Classifying each tool call by effect, applying policy, creating proposals | Running the effect |
| Proposal queue | Proposal state, holds, execution after approval, receipts | Asking the model anything |
| Connectors | Talking to Gmail, Google Calendar, EventKit (through the shell), Messages (through the shell), MCP servers | Policy |
| Scheduler | One timer wheel for routines, holds, idle sessions, mail polls, episode gaps | Running work itself; it posts to the Router or the Proposal queue |
| Store | All Maestro state, transactions, migrations, FTS | Model context |
| Event bus | Delivering events after their transaction commits, batching `run.text` | Persistence |

## 3. Ownership rules

1. **The core is the only writer** of the SQLite file and the pi session files. The shell keeps one file of its own: the last snapshot, for painting at launch.
2. **The shell is the only process with macOS permissions.** The core asks it.
3. **Bot files belong to the user.** The core reads them; bots cannot write them (security.md §4).
4. **Events follow commits.** No event describes state that is not yet in the store, except `run.text` deltas, which are rebuilt from pi on restart or lost (operations.md §2).

## 4. Lifecycle

### Launch

1. The app paints from its cached snapshot.
2. It starts `maestro-core` with the workspace path, state path and a protocol version.
3. The core opens the store, runs migrations, marks runs that were `running` as `interrupted`, returns held proposals to `pending` (permissions.md §5), loads the workspace, and answers `hello` with a snapshot.
4. The scheduler starts. Missed routines are handled (routines.md §4).
5. Connectors start in the background: mail sync, MCP servers. Their health arrives as events.

### Running

- Sessions are created on first use and disposed after 10 minutes idle, or when more than 24 are live (least recently used first). A disposed session reopens from its JSONL in about 10 ms (runtime.md §5).

### Quit

1. The shell sends `shutdown`.
2. The core stops accepting commands, aborts running runs (they become `interrupted`), cancels holds (they return to `pending`), flushes the store, closes MCP servers, and exits.
3. If the core has not exited after 3 s, the shell kills it. The next launch recovers the same way as after a crash.

### Crash

The shell restarts the core with backoff 0.5 s, 1 s, 2 s, 5 s. After 5 crashes in 60 s it stops and shows the last error from `logs/core.log`. Recovery is the launch path above.

## 5. Packaging

```
Maestro.app/Contents/
  MacOS/Maestro                 Swift app
  Resources/core/node           Node 24 binary (Q4: bundled by default)
  Resources/core/maestro-core.mjs   one esbuild bundle of the core, pi included
  Resources/core/node_modules/  only packages that cannot be bundled
```

- The core's dependencies are pinned to exact versions. pi upgrades are a deliberate change with the test suite run against them (operations.md §5).
- Code signing covers the Node binary. It needs the hardened-runtime JIT entitlement.

## 6. Paths

| What | Default path | Changeable |
|---|---|---|
| Workspace (bots, skills, routines, AGENTS.md) | `~/Maestro/` | Yes, in Settings |
| State (database, sessions, logs, caches) | `~/Library/Application Support/Maestro/` | No |
| Bot working folders (for file tools) | `~/Maestro/work/<bot>/` | Per bot, in its file |
| Secrets | macOS Keychain, service `ai.maestro`, through the shell | No |

storage.md §3 lists every file under the state folder.
</content>
