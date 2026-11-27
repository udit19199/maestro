# Runtime

How an input becomes runs, how runs use pi, and how bots work together.

## 1. Inputs

Every run starts from one of these. The Router turns each into zero or more run requests.

| Input | From | Thread |
|---|---|---|
| User message | `message.send` | The given thread |
| Channel message | iMessage watcher (channels.md) | The bound channel thread |
| Routine fire | Scheduler (routines.md) | The routine's thread, new episode |
| Hand-off | `message_bot` tool | Source thread or a new task thread (§6) |
| Hand-off result | A hand-off's target run ended | The sender's thread |
| Action result | An action the bot asked to hear about reached a final state | The action's thread |

## 2. Who answers

**Direct, task and routine threads:** the member bot or bots. A routine thread with several bots uses the group rules.

**Group and channel threads:**

1. Find `@name` mentions at word boundaries, matched against every member's `mentionNames` (case-insensitive). `@everyone` means all members.
2. If there are mentions, those bots answer, in the order mentioned.
3. If none, the thread's `defaultResponder` decides: `lead` (default), `everyone`, or `last_speaker` (the bot that spoke last; the lead if none has).
4. A mention of a bot that is not a member gets a system line: "Mira is not in this chat. Add her?" No run.

Bots that answer the same message run **in parallel**, each in its own session. Their replies get `seq` in the order they finish. Each bot is given every line since its `seen_seq` (§4), so the second bot to answer sees the first one's reply only if it finished first. That is deliberate: no waiting on each other. A bot that needs another bot's answer asks for it with `message_bot`.

## 3. Runs and the queue

- A run belongs to one session. A session runs one run at a time (invariant 3). New run requests for a busy session wait in `queued`, in order.
- **User message to a busy bot:** it is queued as a new run. pi's `followUp` is not used, so every user message is its own run with its own status. The shell shows "Queued" on it.
- **Stop:** `session.abort()`, run becomes `stopped`. Queued runs for that session stay queued.
- **Retry:** a new run with the same cause, in the same session.
- **Budget per run:** 40 tool calls and 15 minutes wall time by default. On either, the core aborts the run with `failed` and the text "Stopped after 40 tool calls" (settings can raise it).

A run's steps:

1. Get or create the session (§5). Move the run to `running`.
2. Build the input: for a group, every message after `seen_seq`, formatted as `[Name]: text` lines, then the new message. Set `seen_seq` to the thread's `last_seq` in the same transaction.
3. The context builder supplies the per-run blocks (context.md §3) through the Maestro extension's `before_agent_start` handler.
4. `session.prompt(input)`. Map pi events to Maestro events (§8).
5. On `agent_settled`: write the final text to the bot's message (`status: complete`), store usage, move the run to `completed` (or `failed` with the mapped error), and start the next queued run.

## 4. Sessions and episodes

- A session is keyed by (episode, bot). It is created the first time that bot runs in that episode, and never used by any other thread (invariant 1, goal G2).
- Three threads that mention the same bot are three sessions. They can run at the same time.
- An episode closes on: the user's "New context" (`thread.newEpisode`), a channel gap or `new` command (channels.md §4), the end of a routine run. Closing writes a carry-over (context.md §7). The next message opens a new episode with new sessions.
- Compaction is pi's. It happens inside a session and does not close the episode.

## 5. pi inside the core

One pi `ModelRuntime` for the whole core, with API keys set from Keychain at start through `setRuntimeApiKey` (pi `examples/sdk/09-api-keys-and-oauth.ts`). Then per session:

```ts
const { session } = await createAgentSession({
  cwd: bot.workDir,
  agentDir: statePath + "/agent",
  modelRuntime,
  model, thinkingLevel,
  sessionManager: existing ? SessionManager.open(jsonlPath) : SessionManager.create(bot.workDir, sessionsDir),
  resourceLoader, // AGENTS.md from the workspace, the bot body as a context file, the bot's skills only
  excludeTools: deniedBuiltIns(bot.tools), // pi built-ins the bot may not use (files, bash)
  customTools: maestroTools(bot), // §7
});
await session.bindExtensions({ uiContext: maestroUi(runId) });
```

- **Why `excludeTools`, not `tools`:** a `tools` list restricts the session and hides MCP and codemode tools (pi `examples/sdk/14-codemode-mcp.ts`).
- **Resource loader per bot:** loads the workspace `AGENTS.md`, the bot file's body, and only the skills the bot lists. It does not walk up from `cwd` (bot work folders sit under the workspace, so the workspace `AGENTS.md` is loaded once, explicitly).
- **The Maestro extension** is one factory, given to every session. It registers the `tool_call` gate (permissions.md §4), the `before_agent_start` context blocks, and the event mapping.
- **MCP:** pi's MCP extension keeps its connections per extension instance (assumption A2). The core gives every session the same transports through `McpExtensionOptions.createTransport`, so each MCP server runs once. If A2 fails, MCP tools are wrapped as Maestro custom tools that call one shared MCP client.
- **Code mode:** on by default for MCP servers with many tools, through pi's codemode extension. `PI_CODEMODE_MAX_WORKERS` is set to 4.
- **Live sessions:** disposed after 10 minutes idle, or least recently used first when more than 24 are live. Reopening reads the JSONL (about 10 ms; to measure, assumption A1).

## 6. Hand-offs

`message_bot({ to, text, wait })`:

1. The gate checks: target exists and is `active`; the chain is under 4 hops and the root under 12 runs (invariant 8). Otherwise the handoff is `blocked` and the tool returns why.
2. **Target is a member of this thread:** the core writes a `handoff` message in this thread ("Mail → Calendar: is Tue 3 pm free?") and starts a run for the target here. Everyone in the thread sees it.
3. **Target is not a member:** the core creates a `task` thread under this one with the target as its member, writes the `handoff` message there, and runs the target there. Its audience is the source thread's.
4. The tool returns at once: "Sent to Calendar. Its answer will come back here." The sender's run carries on or ends.
5. When the target's run ends, its final text becomes a `handoff_result` message in the source thread, and a `handoff_result` run starts for the sender, so it can use the answer. With `wait: false` the result is posted but the sender is not woken.

Hand-off text is marked as coming from a bot, never from the user (security.md §3).

## 7. Maestro tools

Always on for every bot, defined in the core, gated like any tool:

| Tool | Effect | What it does |
|---|---|---|
| `message_bot` | local | §6 |
| `memory_add`, `memory_update`, `memory_remove` | local | context.md §4 |
| `ledger_add`, `ledger_close` | local | context.md §4 |
| `flag_for_user` | local | A `needs_user` ledger item; shows in Today |
| `notify_user` | local | Sends a short note to the owner's iMessage self-chat (channels.md §6) |
| `search_threads`, `read_thread` | read | context.md §5 |

On when the bot's `tools` allow it: mail tools, calendar tools, `messages_send`, and pi's file and shell tools. Their effect classes are in permissions.md §2. Each tool returns a short `label` for the UI ("Searching mail: unread in inbox") built by the tool, never by the shell.

## 8. pi events to Maestro events

| pi | Maestro |
|---|---|
| `message_update` text delta | `run.text` (merged, 33 ms) |
| `tool_execution_start` | `tool_calls` row, `run.tool` running |
| `tool_execution_end` | row updated, `run.tool` ok/error |
| auto-retry start | `run.status` retrying |
| compaction start | `run.status` compacting |
| `agent_settled` | final message, `run.ended` |
| provider error after retries | `run.ended` failed with `RunError` kind mapped from the HTTP status: 401/403 `provider_auth`, 429 `rate_limited`, connection refused `provider_down`, context too long `context_overflow`, else `model_error` |

## 9. Concurrency model

- The core is one Node event loop. SQLite writes are synchronous and short. Network, model and MCP calls are async.
- Parallel runs are limited only by the model provider. The core caps concurrent runs at 8; more wait in `queued` with status text "Waiting for a free slot".
- A slow tool (a mail sync, an MCP call) never holds the writer. Tools write their results in their own short transactions.
</content>
