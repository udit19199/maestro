# Context: what a bot sees

The rule (decision D6): **a bot's threads never share a context window.** Continuity comes from layers that are small, typed and filtered, never from copying transcripts between threads.

## 1. The problem, with an example

Mail is in three threads: the Desk (a group with Calendar), a direct chat about a job offer, and an iMessage channel.

- If all three fed one session (the way some bots work), the Desk sweep would carry the offer negotiation in its context. Every turn costs more, compaction throws away the wrong things, and text from one chat can leak into another.
- If the three were fully separate, Mail in the Desk would not know it promised Priya a reply in the iMessage chat an hour ago.

Maestro keeps the sessions separate and passes only what matters across.

## 2. The layers

| Layer | Holds | Size cap | In every run? | Store |
|---|---|---|---|---|
| **Identity** | Workspace `AGENTS.md`, the bot file body, skill names and descriptions | AGENTS.md 4 KB, bot body 8 KB | Yes, stable | Files |
| **Memory** | Lasting facts: about the user (workspace scope) and the bot's own (bot scope) | 40 entries × 300 chars per scope | Yes | `memory_entries` |
| **Ledger** | The bot's open work across all its threads | 15 items, one line each | Yes | `ledger_items` |
| **Thread** | This thread's own history, in its own pi session | pi's compaction | Yes, it is the session | pi JSONL |
| **Recall** | Other threads' messages | Tool result, 4,000 chars | Only when the bot calls a tool | `messages` + FTS |

## 3. Assembly order

Stable parts first, so the provider's prompt cache holds across runs and threads:

```
[system]  pi base prompt + tool declarations                         (pi)
[system]  Workspace AGENTS.md                                       (context file)
[system]  Bot body                                                  (context file)
[system]  Skills list                                               (pi)
[system]  <maestro_rules> how to use memory, ledger, proposals </maestro_rules>   (fixed text)
[section] <memory> workspace facts, then bot facts </memory>        (changes rarely)
[section] <ledger> open items </ledger>                             (changes often)
[section] <thread> kind, members, audience, channel, today's date and time </thread>
[section] <carry_over> summary of the previous episode </carry_over> (first run of an episode only)
...       this session's messages (pi)
[user]    the new input
```

- The `<memory>`, `<ledger>`, `<thread>` and `<carry_over>` blocks are set in the Maestro extension's `before_agent_start` handler through `systemPromptOptions.sections`. pi diffs the sections against what the model already has and appends one system message patching only the changed ones, so the earlier prefix stays cached on models that accept mid-conversation system messages (pi `docs/extensions.md` "before_agent_start"; assumption A3).
- The total of these four blocks is capped at 3,000 tokens. Over the cap, the ledger drops `follow_up` items with the latest `dueAt` first, then memory drops the oldest bot-scope entries. The bot is told how many were dropped and that `search_threads` and the memory tools can see the rest.

Example of the blocks for Mail's run in the Desk:

```
<memory>
About Udit: works in Jaipur, IST. Prefers short replies. Bank is HDFC.
Mail: Udit archives newsletters unread. Priya Shah is a recruiter at Acme.
</memory>
<ledger>
L-31 promise · reply to Priya with Tue/Wed slots · from iMessage, 1 h ago
L-29 proposal · P-12 send "Re: Invoice 4471" · waiting on Udit
L-27 needs_user · HDFC KYC upload due 30 Nov
</ledger>
<thread>group "Desk Fri 27 Nov" · members: Mail (lead), Calendar · private · now Fri 27 Nov 09:02 IST</thread>
```

## 4. Memory and ledger writes

Bots write through tools only. Every write records its origin (thread, message, run, audience) and goes through the store in order, so two threads never overwrite each other.

| Tool | Rule |
|---|---|
| `memory_add({ text, scope: "bot" \| "workspace" })` | One fact per entry, at most 300 characters. Refused if the scope is full; the bot must update or remove first. The core strips anything that looks like a secret (API keys, card numbers, OTPs) and refuses if it finds one |
| `memory_update({ id, text })`, `memory_remove({ id })` | Journaled; the user can undo any change from Settings > Memory |
| `ledger_add({ kind, summary, dueAt? })` | `summary` at most 140 characters. Kinds `promise`, `waiting`, `follow_up` |
| `ledger_close({ id, note? })` | Closes as `done`; `dropped` needs a note |
| `flag_for_user({ summary, detail, dueAt? })` | A `needs_user` item |

The core writes ledger items itself for every pending proposal (`kind: proposal`) and closes them when the action reaches a final state. When a `follow_up` item's `dueAt` passes, the core starts a run for its bot in the item's origin thread (routines.md §5).

Memory is not a diary. The rules text tells bots: write a fact only if it will still be true and useful in a month. Day-to-day state belongs in the ledger.

## 5. Recall

| Tool | Returns |
|---|---|
| `search_threads({ query, limit? })` | Up to 10 hits: thread title, date, author, a 200-character snippet, message id |
| `read_thread({ threadId, aroundMessageId?, limit? })` | Up to 30 messages around a point, 4,000 characters in total |

Both search only threads the bot is or was a member of, and obey the audience rule (§6). They read the transcript, not other sessions' model context.

## 6. Audience rule

- Every thread has an audience: `private` (only the owner and bots read it) or `shared` (other people are in it: an iMessage group with friends).
- Every memory entry and ledger item records the audience of the thread it came from.
- **In a `shared` thread, the bot sees only items whose origin is `shared` and, for memory, workspace facts the user wrote themself.** Recall in a shared thread returns only shared threads.
- The core applies this when it builds the blocks and when it answers recall tools. The model is never trusted to filter.
- A private item can be shown in a shared thread only after the user marks it `shared` in Settings > Memory (it then records `writtenBy: user`).

## 7. Episodes and carry-over

When an episode closes (runtime.md §4), the core writes a carry-over: at most 600 characters, made by a small model call over the episode's transcript with the instruction "What would this bot need to continue, if this chat picked up tomorrow? Facts and open threads only." If the model call fails, the carry-over is the last three messages, cut.

The next episode's first run gets it in `<carry_over>`. Later runs in the episode do not; by then it is in the session's history.

Desktop threads rarely close episodes, so the carry-over matters mostly for iMessage and routines.
</content>
