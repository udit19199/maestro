# Operations

## 1. Health

The core reports `Health` (types/protocol.ts) in the snapshot and on every change:

| Part | Checked |
|---|---|
| Model | On start, then from real calls; a failed call sets `down` or `auth_failed` until the next success |
| Connections | Mail sync result; MCP server start and exit |
| Calendar, Messages access, network | The shell sends `host.status` at connect and on every change (network from `NWPathMonitor`) |

## 2. Crash and restart

What happens to each kind of state if the core dies at any moment:

| State at crash | On restart |
|---|---|
| Run `running` | `interrupted`. Its message keeps the text written at start (empty) and shows "Interrupted" with Retry. Streamed text since the start is lost; pi's session file may have more of it, which the next run sees |
| Run `queued` | Stays queued, runs in order |
| Action `held` | Back to `pending`. Never runs without a new approval |
| Action `executing` | `unknown`. Never retried by itself |
| Routine slot fired, run not finished | The `routine_runs` row exists, so the slot does not fire again; outcome `failed` |
| Inbound iMessage read, not stored | Read again from the cursor; the guid check stops doubles |
| Memory or ledger write | Committed or not; no partial state |

Rule: **anything that reaches outside runs at most once; anything inside may be redone.**

## 3. Logs

- `logs/core.log`: one JSON line per entry (time, level, component, thread, run, message). 10 MB per file, 5 files.
- What is logged: commands, state changes, connector errors, timings over budget. What is not: message text, tool arguments, mail content, secrets. A debug setting turns on argument logging for 1 hour.
- Settings > About > Copy diagnostics: versions, health, the last 500 log lines, schema version. Nothing is sent anywhere.

## 4. Backups

- Daily at the first idle moment: `VACUUM INTO backups/maestro-<date>.db`, 7 kept. Session files are not backed up (episodes and carry-overs survive without them).
- The workspace folder is the user's: they can put it in git or iCloud Drive.

## 5. Testing

| Layer | How |
|---|---|
| Store | Unit tests on an in-memory database: every invariant in domain.md §4, every migration from an older fixture |
| Types vs SQL | A test reads the TypeBox enums and the `CHECK` lists in schema.sql and fails if they differ |
| Gate and policy | Table tests: (tool, args, bot, thread, unattended) → rule |
| Runtime | pi's faux provider (`@earendil-works/pi-ai` `fauxProvider`) scripts model replies and tool calls; tests drive the core over its real stdio protocol |
| Connectors | Gmail and IMAP against recorded fixtures; one opt-in live test per connector |
| Protocol | Recorded core output decoded by the generated Swift types (contract test) |
| Crash recovery | Kill the core at each point in §2 from a test harness; check the restart outcome |
| App | The `verify-maestro` skill: a full walkthrough in the running app |

A pi upgrade is one PR that bumps the exact version and runs all of the above.

## 6. Checking the assumptions

| # | Assumption (requirements.md §6) | Test before building on it |
|---|---|---|
| A1 | Sessions stay small | 20 sessions, 200 messages each with tool output; measure RSS |
| A2 | Shared MCP transports | Two sessions, one stdio server through `createTransport`; count server processes |
| A3 | Sections keep the cache | Two runs, ledger changed between them; read `cacheReadTokens` |
| A4 | Child covered by app grants | Core reads `chat.db` with Full Disk Access given only to Maestro.app |
| A5 | Reply link in `chat.db` | Reply to a message on iPhone; read `thread_originator_guid` |
| A6 | `node:sqlite` | WAL, FTS5 with `contentless_delete`, 10,000 inserts while reading |

If one fails, the fallback is in the file that depends on it.

## 7. Performance budgets

requirements.md §5 sets them. Each has a test in CI that fails over budget: snapshot time with 500 threads, history page time with 2,000 messages, `run.text` rate, idle RSS with 20 sessions.
</content>
