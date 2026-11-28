# Requirements

## 1. What Maestro is

A general bot platform for one person on one Mac. The person defines bots in files, talks to them in threads and group chats, lets them hand work to each other, runs them on schedules, and reaches them from iMessage. Mail and calendar are the first real use; the core does not know about mail beyond what a connector gives it.

It is open source. Each user installs the app and runs their own instance.

## 2. Goals

| # | Goal | Test of done |
|---|---|---|
| G1 | A solid core: every state change is typed, stored in one place, and survives a crash | Kill the core during a run, a proposal hold and a routine; on restart nothing is lost or done twice (operations.md §2) |
| G2 | No context pollution: a bot's threads never share one context window | Three threads that mention the same bot run as three pi sessions (runtime.md §4) |
| G3 | Continuity anyway: a bot knows its open work and lasting facts in every thread and channel | A promise made in thread A shows in thread B's ledger block (context.md §4) |
| G4 | Low friction: no approval for reads, Maestro-only changes or reversible changes to the user's own data | A sweep that labels 20 mails asks nothing (permissions.md §3) |
| G5 | Nothing other people see, and nothing permanent, happens without the user's yes | Every `outward` and `destructive` action goes through a proposal (permissions.md §4) |
| G6 | Bring your own model: any pi provider, with Relay as one option | Switching provider is a setting, not code |
| G7 | Open files: bots, skills and routines are readable by other agent tools | A bot file loads in Claude Code through the `.claude/agents` link (bot-files.md §5) |
| G8 | Routines run while the window is closed | A 08:00 routine runs with only the menu bar icon showing (routines.md) |
| G9 | Mail sign-in with no backend and nothing run by the maintainer | A new user connects Gmail with an app password in about 2 minutes, without opening Google Cloud (connectors.md §2) |

## 3. Non-goals for v1

- Other platforms (Linux, Windows, iOS app, web UI).
- A Maestro server, account, sync, telemetry or crash upload.
- Several human users in one instance. Group threads have one human, the owner. A channel thread may include other people (an iMessage group) and is marked `shared` (context.md §6).
- A marketplace or bot sharing service. Export is a folder.
- Browser or computer use built into the core. A bot gets it through MCP or a skill.
- Running the core without the app.

## 4. Constraints

- macOS 14 or later, Apple silicon. The shell is SwiftUI.
- pi (`@earendil-works/pi-coding-agent`), pinned to an exact version, embedded through its SDK.
- Node 24, bundled in the app (open question Q4).
- No dependency on a third-party token broker (Composio and similar). A user's tokens stay on their Mac.
- The maintainer runs no server and owns no Google Cloud project. v1 mail is Gmail over IMAP with an app password (connectors.md §2).
- dusk.bot is source-available under PolyForm Noncommercial: read for ideas, never copy code.

## 5. Quality targets

These are the product's edge (decided 28 Nov 2026): the least memory, the fastest replies and the tightest security of any bot app. Every PR that touches the core or the shell reports its effect on the memory and speed rows below; a PR that makes one worse needs a reason.

- **Memory:** one core process for all bots, never one process per chat. Today's app starts one pi process per chat, each about 100 MB (pi loaded in Node measured 96 MB RSS, A1), so 20 chats cost about 2 GB; in one process the same 20 cost 182 MB.
- **Speed:** the model's wait is most of the time, so the core cuts what it sends: prompt cache hits on every turn (A3, needs Relay session affinity), warm sessions, and the core rules in §7 that cut model turns and retries. Running tool calls from a model-written script (pi's code mode) is off by default: in the §7 test it gave no speed gain and cost 30-55 MB.
- **Security:** no open port, secrets only in Keychain, bot scripts confined with no file, network or environment access.

Measured on an M-series Mac with 24 GB. The design file for the shell (`docs/DESIGN.md` §7) owns UI frame targets; these are the core's.

| What | Target |
|---|---|
| App launch to first painted snapshot | under 150 ms (shell paints its cached snapshot before the core answers) |
| Core start to `hello` answered with a full snapshot | under 400 ms with 500 threads |
| Send to first `run.text` event, model time excluded | under 50 ms for a warm session, under 120 ms for a cold one |
| Text batching | at most one `run.text` per run per 33 ms |
| Core memory, 20 sessions after 200 messages each, no MCP | under 250 MB RSS (spike: 182 MB) |
| Shell memory, window open, 500 threads | under 80 MB RSS |
| Prompt cache | at least 90% of input tokens read from cache from the second turn of a thread |
| Opening a thread with 2,000 messages | first page of 50 in under 30 ms |
| Crash to recovered core | under 2 s, no user action |
| Data loss on crash | none for committed state; at most the text of a run in progress |

## 6. Assumptions to check while building

Each is a claim the design depends on that nobody has tested yet. operations.md §6 lists the test for each.

Spikes run 28 Nov 2026 on pi 1.2.0, Node 26.13.1, scripts in `~/Workspace/local/maestro/spikes-2026-11-28/`.

| # | Assumption | Result |
|---|---|---|
| A1 | Many `AgentSession`s in one process stay small after real use | **Held.** 20 sessions × 201 messages (2 KB tool output each, 2,000 faux model calls): 0.66 MB heap per session, 182 MB RSS for the whole process |
| A2 | One MCP server process can serve all sessions through `McpExtensionOptions.createTransport` | **Held, with Maestro code.** By default each session starts its own server (3 sessions → 3 processes). A shared transport in `createTransport` (one stdio connection, per-session id rewriting, cached `initialize`) gave 1 process and correct results for all 3. Server-sent notifications (`tools/list_changed`) must be broadcast to every session; not built yet |
| A3 | The ledger can change between runs without breaking the prompt cache | **Held as a section, failed as a prompt rewrite.** Haiku through Relay, 11.8k-token prefix, ledger changed before run 3: as `systemPromptOptions.sections.ledger`, run 3 read 11,859 tokens from cache; appended to the full system prompt, run 3 read 0. **Needs Relay `routing.session-affinity: true`**: with it off (Udit's config), round-robin over 3 Claude accounts gave 0 cache reads on every run, changed or not |
| A4 | A child process started by `Maestro.app` is covered by the app's Full Disk Access and Automation grants (needed for iMessage) | Not run: needs a Full Disk Access grant |
| A5 | `chat.db` records which message an iMessage reply answers (`thread_originator_guid`) | Not run: needs a reply from an iPhone |
| A6 | `node:sqlite` handles WAL, FTS5 and one writer with readers | **Held** on Node 26 (SQLite 3.54.1): schema.sql loads, 10,000 FTS inserts in 643 ms while a reader thread ran 13,300 searches with 0 errors (max 5.5 ms); `contentless_delete` removes rows. Not rerun on Node 24 |

## 7. Core rules that came out of testing

Tested 28 Nov 2026 with two bots (Nami reads two job postings and hands the skill gaps to Jinbei; Jinbei builds a learning plan in Excalidraw over its MCP server), Grok through Relay, each board read back from Excalidraw and checked by a program. Code in `core/bench/`, results in `~/Workspace/local/maestro/bench-2026-11-28/`. One model and one tool server, so the numbers are a first reading.

| Rule in the core | Why | Measured |
|---|---|---|
| A bot always sees the full description of every tool it may use | With descriptions hidden behind a search step, Jinbei guessed arguments | Hidden: 28 model turns, 10 of 17 calls failed. Shown: 2-3 turns, 0 failed |
| The bot file lists the tools the bot may use (`maestro.mcp: { server: [tools] }`); nothing else is declared or reachable | Tool descriptions are sent on every model turn | 14 tools 34.6 KB, 7 tools 23.9 KB per request; small task 35k → 27k tokens read |
| Tool calls run one at a time by default; scripts (code mode) are opt-in | Same task, same input, 5 runs each | Small task: direct 24 s and 141-145 MB, code mode 40 s and 195-200 MB. Large task: no difference in time |
| A bot hands off by writing `@bot` in its reply; no tool call | The model sometimes wrote "message sent" without calling the hand-off tool | Tool: 5 of 9 hand-offs arrived, 4 model turns. Reply: 10 of 10, 2 turns |
| MCP tools that change data run in order; read-only tools (`readOnlyHint`) run in parallel | Four writes to one scene at once were rejected ("changed too often") and overlapped, then the bot spent turns repairing | Large task: 12 → 5 model turns, 252k → 90k tokens read, 128 s → 79 s (medians) |
| An identical call that failed twice is not run a third time; a run stops after 3 turns of only failed calls | One run repeated the same failing calls 36 times | Covered by `core/bench/faux-handoff.ts` |
| Every failed tool call keeps its error text in the run record | The cause of failures could not be found without it | — |

Not built yet: the in-order rule holds inside one bot's run; two bots writing to the same server at once are not yet queued.
