# Maestro architecture

Status: design, not built. Written 27 Nov 2026. Code on `main` still follows [current-state.md](current-state.md).

Maestro is a local Mac app where named bots do work for one person. Each user runs their own copy. There is no Maestro server and no Maestro account.

## How to read this

Read in order. Each file owns one concern; other files link to it instead of repeating it.

| # | File | Owns |
|---|---|---|
| 0 | [current-state.md](current-state.md) | How `main` works today, with measured costs |
| 1 | [requirements.md](requirements.md) | Goals, non-goals, constraints, quality targets |
| 2 | [system.md](system.md) | Processes, components, who owns what, lifecycle |
| 3 | [domain.md](domain.md) | Entities, relationships, state machines, invariants |
| 4 | [types/](types/) | The TypeScript types: `domain.ts`, `protocol.ts`, `bot-file.ts`. They are the spec; prose that disagrees with them is the bug |
| 5 | [storage.md](storage.md) + [schema.sql](schema.sql) | SQLite schema, files on disk, retention, migrations |
| 6 | [protocol.md](protocol.md) | Core ↔ shell wire protocol |
| 7 | [runtime.md](runtime.md) | Message routing, runs, sessions, hand-offs, concurrency, pi SDK use |
| 8 | [context.md](context.md) | What a bot sees: identity, thread, ledger, recall, episodes |
| 9 | [permissions.md](permissions.md) | Effect classes, policy, proposals, holds, undo |
| 10 | [connectors.md](connectors.md) | Google sign-in, Gmail, calendar, MCP, models, secrets |
| 11 | [channels.md](channels.md) | Desktop and iMessage, episode rules |
| 12 | [routines.md](routines.md) | Schedules, triggers, missed runs, unattended rules |
| 13 | [bot-files.md](bot-files.md) | `.agents/` folder layout and bot file format |
| 14 | [security.md](security.md) | Threat model, trust boundaries, injection |
| 15 | [operations.md](operations.md) | Failure handling, recovery, logs, testing, performance budgets |
| 16 | [build-plan.md](build-plan.md) | Migration from today's app and the PR order |

## Words used everywhere

| Word | Meaning |
|---|---|
| **Core** | The Node process `maestro-core`. It runs pi through the SDK and owns all logic and storage. |
| **Shell** | `Maestro.app`, the SwiftUI app. It draws the UI and provides Mac services (Keychain, EventKit, Messages). |
| **Bot** | A named agent defined by one file, `.agents/agents/<bot>.md`. |
| **Thread** | One conversation: direct (one bot), group (several bots), routine, or channel. |
| **Session** | One pi `AgentSession`: the model context of one bot in one episode of one thread. |
| **Episode** | One stretch of a thread that shares one session. Desktop threads usually have one; iMessage and routine threads roll to a new episode after a gap. |
| **Run** | One bot working on one input until pi settles. |
| **Action** | A tool call with an effect outside the model, checked against policy. An action that waits for the user is a **proposal**. |
| **Ledger** | A bot's list of open work (promises, waits, proposals), shown to it in every thread. |
| **Effect class** | How far an action reaches: `read`, `local`, `own`, `outward`, `destructive`, `exec`. See [permissions.md](permissions.md). |

## Decisions

Each line is settled. A change needs a new line, not an edit.

| # | Date | Decision | Why | Where |
|---|---|---|---|---|
| D1 | 2026-11-05 | pi is the agent harness | Its compaction, sessions, retries and MCP are better than a home-made one | runtime.md |
| D2 | 2026-11-27 | One core process embeds pi through the SDK, one `AgentSession` per thread × bot × episode | 116 MB per pi process today vs about 2 MB per SDK session (measured, pi 1.6.1) | system.md |
| D3 | 2026-11-27 | Mac only, for everything | One user, one platform; no portability layers | requirements.md |
| D4 | 2026-11-27 | Local only: no Maestro server, no Maestro account | Each user is their own instance; nothing for us to run or pay for | requirements.md |
| D5 | 2026-11-27 | The shell is the parent of the core and talks to it over stdio | The app stays running as a menu bar app; macOS permissions belong to one app bundle | system.md |
| D6 | 2026-11-27 | A bot's threads never share a context window. Continuity comes from memory, the ledger and recall tools | No context pollution, yet continuity across threads and channels | context.md |
| D7 | 2026-11-27 | SQLite is the store for everything Maestro owns. pi's JSONL is the store for model context only | One writer, transactions, FTS; pi keeps its own compaction format | storage.md |
| D8 | 2026-11-27 | Reads, Maestro-only changes and reversible changes to the user's own data run without asking. Anything other people see, and anything permanent, asks first | Users want no approval friction; a send cannot be taken back | permissions.md |
| D9 | 2026-11-27 | Asking never blocks the bot: an outward action becomes a proposal and the tool returns at once | One sweep can leave five proposals without waiting between them | permissions.md |
| D10 | 2026-11-27 | Maestro ships no OAuth client. Mail defaults to an app password; users can add their own Google Desktop OAuth client (loopback + PKCE) for the Gmail API | The maintainer runs and owns nothing: no Cloud project, no user cap, no verification | connectors.md |
| D11 | 2026-11-27 | Bots, skills and routines are open-standard files under one workspace folder; state is in Application Support | Users and other tools can read and edit them; git works | bot-files.md |
| D12 | 2026-11-27 | Types are defined once in TypeBox in the core; JSON Schema is generated from them; Swift `Codable` types are generated from the schema | One source for wire types, checked at the trust boundary | protocol.md |
| D13 | 2026-11-27 | dusk.bot code is read, never copied (PolyForm Noncommercial) | License | — |

## Open questions

Each has an owner and a default. Build uses the default until it is answered.

| # | Question | Default | Blocks |
|---|---|---|---|
| Q2 | iMessage: the owner's self-chat, or a second Apple ID for the bot (which takes over the Mac's Messages)? | Self-chat | channels.md §3 |
| Q3 | Episode gap for iMessage | 2 hours | channels.md §4 |
| Q4 | Bundle Node in the app, or require Node on the system? | Bundle Node 24 | system.md §5 |
</content>
