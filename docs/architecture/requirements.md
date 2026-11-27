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

Measured on an M-series Mac with 24 GB. The design file for the shell (`docs/DESIGN.md` §7) owns UI frame targets; these are the core's.

| What | Target |
|---|---|
| App launch to first painted snapshot | under 150 ms (shell paints its cached snapshot before the core answers) |
| Core start to `hello` answered with a full snapshot | under 400 ms with 500 threads |
| Send to first `run.text` event, model time excluded | under 50 ms for a warm session, under 120 ms for a cold one |
| Text batching | at most one `run.text` per run per 33 ms |
| Core memory, idle, 20 live sessions, no MCP | under 400 MB RSS |
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
