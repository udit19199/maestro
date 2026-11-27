# Domain model

The exact fields are in [types/domain.ts](types/domain.ts) and the tables in [schema.sql](schema.sql). This file explains the shape, the life of each thing, and the rules that must always hold.

## 1. Entities

```
Workspace 1 ── * Bot (file)            Workspace 1 ── * Routine (file)
                 │                                      │
Thread * ── * Bot   (ThreadMember)      Routine 1 ── * RoutineRun ── 1 Thread/Episode
  │
  ├─ 1 ── * Episode ── * Session (one per bot in the episode) ── 1 pi JSONL file
  ├─ 1 ── * Message (seq per thread)
  ├─ 1 ── * Run ── * ToolCall ── 0..1 Action
  └─ 0..1 ChannelConversation ── * ChannelMessage ── 1 Message

Bot 1 ── * MemoryEntry       Bot 1 ── * LedgerItem
Run 0..1 ── * Handoff ── 1 Thread (kind task)
Connection (Google, IMAP, MCP) 1 ── * MailMessage (cache)
```

| Entity | What it is | Identity | Stored in |
|---|---|---|---|
| Bot | A named agent | `BotId`: the file stem, `[a-z0-9-]{1,40}` | File; `bots` row keeps load state |
| Skill | An Agent Skill folder | Folder name | File only |
| Routine | A schedule plus a prompt and a target | `RoutineId`: the file stem | File; `routines` row keeps run state |
| Thread | A conversation | `thr_<ulid>` | `threads` |
| ThreadMember | A bot in a thread | (thread, bot) | `thread_members` |
| Episode | A stretch of a thread with one context window per bot | `ep_<ulid>`, plus `n` per thread | `episodes` |
| Session | One bot's pi session in one episode | `ses_<ulid>` (also the pi session id) | `sessions` + JSONL |
| Message | One line in the transcript | `msg_<ulid>`, plus `seq` per thread | `messages` |
| Run | One bot working on one input until pi settles | `run_<ulid>` | `runs` |
| ToolCall | One tool call inside a run | pi's tool call id | `tool_calls` |
| Action | A tool call with an effect, after the gate | `act_<ulid>`, plus a short number shown as `P-12` | `actions` |
| Handoff | One bot giving work to another | `hof_<ulid>` | `handoffs` |
| LedgerItem | Open work the bot must not forget | `led_<ulid>` | `ledger_items` |
| MemoryEntry | A lasting fact | `mem_<ulid>` | `memory_entries` + `memory_journal` |
| Connection | A signed-in account or server | `con_<ulid>` | `connections`; secret in Keychain |
| ChannelConversation | One outside chat (an iMessage chat) bound to a thread | `chc_<ulid>` | `channel_conversations` |
| ChannelMessage | Link between an outside message and a Maestro message | outside guid | `channel_messages` |

IDs are ULIDs with a type prefix, so they sort by time and a wrong kind of id is visible in logs. Bots and routines use their file stem because users write them in files and in `@mentions`.

## 2. Thread kinds

| Kind | Members | Episodes | Shown in sidebar | Audience |
|---|---|---|---|---|
| `direct` | 1 bot | One, unless the user starts a new one | Yes | `private` |
| `group` | 2 or more bots | One, unless the user starts a new one | Yes | `private` |
| `routine` | The routine's target bots | One per routine run | Under Routines | `private` |
| `channel` | The binding's bot or bots | Rolls on gap or command (channels.md §4) | Under its channel | `private`, or `shared` if other people are in the outside chat |
| `task` | 1 bot | One | Under the thread that started it | Same as the parent thread |

A `task` thread is where a hand-off runs when the target bot is not a member of the source thread (runtime.md §6).

## 3. State machines

### Run

```
queued ──► running ──► completed
   │          ├──────► failed      (error kind and text; retryable flag)
   │          ├──────► stopped     (user pressed Stop)
   │          └──────► interrupted (core quit or crashed during the run)
   └─────────────────► cancelled   (thread deleted, or bot removed, before it started)
```

A run ends when pi emits `agent_settled`. pi's own retries and compaction happen inside `running`.

### Action

```
            ┌──────────── auto (policy says run) ─────────────┐
            │                                                 ▼
proposed ──►pending ──approve──► held ──timer──► executing ──► succeeded ──undo──► undone
            │  │  ▲                │                 ├──────► failed ──retry──► executing
            │  │  └──── undo ──────┘                 └──────► unknown (crash mid-call)
            │  ├──deny──► denied
            │  ├──────► replaced  (the bot proposed a new version)
            │  └──────► expired   (older than 7 days)
            └─ blocked (never-list or policy `deny`; never runs)
```

- `auto` actions skip `pending` and `held` and go straight to `executing`, but they are still rows: they make receipts and undo.
- `unknown` means the core stopped between starting the call and recording its result. It is never retried by itself. The user sees "may have run; check" (operations.md §2).
- `undone` exists only for actions whose connector supplied an inverse (permissions.md §6).

### Episode

```
open ──► closed (gap, `new` command, routine run finished, or user "New context")
```

At most one open episode per thread. Closing writes a carry-over summary (context.md §7).

### Ledger item

```
open ──► done | dropped
```

Closed by the bot (`ledger_close`), by the user, or by the core when the linked action reaches a final state.

### Handoff

```
sent ──► running ──► answered
  └────► blocked (hop limit, budget, unknown bot, bot not allowed)
```

## 4. Invariants

The store enforces these with constraints where SQLite can; the rest have tests (operations.md §5).

1. Every session belongs to exactly one episode and one bot, and each (episode, bot) pair has at most one session. **No session is ever shared between threads.** (Goal G2.)
2. A thread has at most one open episode.
3. A session has at most one run in `running`. Others wait in `queued`, in order of creation.
4. `messages.seq` is gap-free and increasing within a thread. Every bot's `sessions.seen_seq` is at most the thread's last `seq`.
5. An action in `executing`, `succeeded`, `failed`, `unknown` or `undone` has `decision` set to `auto` or `approved`. An `outward` or `destructive` action has `decision = approved`, never `auto`, unless the workspace setting `outward_policy` is `auto` (permissions.md §3).
6. An action runs at most once. The move to `executing` is a compare-and-set on `status`.
7. A memory entry or ledger item from a `private` thread is never shown in a `shared` thread (context.md §6).
8. A hand-off chain is at most 4 hops deep, and one root run causes at most 12 runs in total.
9. Events are sent only after the transaction that caused them commits.
10. Every row that names a bot names one that exists in `bots`, even after its file is deleted: deleting a file marks the bot `removed`, it does not delete history.
</content>
