# Permissions

Decision D8: no asking for things that stay with the user and can be undone. Asking for things other people see and things that cannot be undone. Decision D9: asking never blocks the bot.

## 1. Why a typed table and not name matching

Some platforms decide whether a tool "sends" by matching words in its name (`send`, `post`, `create`). A tool called `deliver_note`, or an MCP tool with an odd name, passes as a read. Maestro gives every tool an **effect class** in a table it owns. A tool with no entry is `outward` until the user classifies it.

## 2. Effect classes

| Class | Meaning | Examples |
|---|---|---|
| `read` | Changes nothing | `mail_search`, `mail_read`, `calendar_list`, `search_threads`, pi `read`, `grep`, `ls`, `find` |
| `local` | Changes only Maestro's own state | `memory_*`, `ledger_*`, `flag_for_user`, `message_bot` |
| `own` | Changes the user's own data, reversibly, and nobody else sees it | `mail_label` (archive, read/unread, star, labels), `mail_draft`, `calendar_create`/`update` with no attendees, pi `write`/`edit` inside the bot's `workDir` |
| `outward` | Someone other than the user can see it | `mail_send`, `mail_reply`, `calendar_create`/`update` with attendees, `calendar_respond`, `messages_send` to someone other than the owner, any MCP tool not classified |
| `destructive` | Cannot be undone | `mail_trash` with permanent delete, `calendar_delete` of an event with attendees, pi `write`/`edit` outside `workDir` |
| `exec` | Runs arbitrary code | pi `bash` |

Some tools pick their class from their arguments: `calendar_create` is `own` with no attendees and `outward` with any. The tool's gate function returns the class for the actual arguments.

MCP tools: each server can declare classes per tool in the workspace's `mcp.json` (`"maestro": { "effects": { "search": "read", "create_page": "own" } }`). Unlisted tools are `outward`. The first time one is proposed, the approval card offers "Always allow this tool" (sets it to `own` for that server).

## 3. Policy

A rule per class is `auto` (run), `ask` (proposal) or `deny` (blocked). Resolution, first match wins:

1. The **never-list** (§7). Always `deny`.
2. The **routine rule** (§8) in unattended runs.
3. The thread's `policy`.
4. The bot's `maestro.policy`.
5. The workspace defaults:

| Class | Default |
|---|---|
| `read` | auto |
| `local` | auto |
| `own` | auto |
| `outward` | ask |
| `destructive` | ask |
| `exec` | auto, but only bots whose file turns `tools.shell` on get the tool at all |

A user who wants full YOLO sets `outward: auto` in Settings. The app shows once what that means and records it. `destructive` cannot be set to `auto` anywhere.

## 4. The gate

The Maestro extension registers one `tool_call` handler (pi `docs/extensions.md` "tool_call"). For every call:

1. Find the tool's effect class for these arguments.
2. Resolve the rule (§3).
3. `deny`: return `{ block: true, reason }`. The action row is `blocked`. The model sees: "Blocked: <reason>. Do not try another way."
4. `auto`: let it run. For classes other than `read` the core writes an action row with `decision: auto`, so a receipt and undo exist.
5. `ask`: write an action row `pending`, a `proposal` ledger item, and return `{ block: true, reason: "Proposed as P-12. Udit will approve or deny it. Do not propose it again; carry on with other work." }`. The run does not wait.

Returning `block` with a reason is how pi lets a handler stop a call and tell the model why; the run continues.

## 5. Proposals

```
pending ── approve ──► held (send: 10 s, other: 5 s) ── timer ──► executing ──► succeeded | failed | unknown
   │                     └─ undo ──► pending
   ├─ deny (note?) ──► denied ──► the note goes to the bot as a new message
   ├─ the bot proposes a new version ──► replaced
   └─ 7 days ──► expired
```

- On approve, the core runs the stored payload (or the user's edited one) through the connector. No model is involved.
- Just before running a mail reply, the core checks the Gmail thread again. If a message arrived after the proposal, the action returns to `pending` with a `thread_changed` warning.
- After the effect, the core writes an `action_note` message in the thread ("P-12 sent to priya@acme.com, 09:12") and adds it to the bot's session as a custom message (`pi.sendMessage`, no new turn), so the bot's next run knows.
- On deny with a note, the note becomes a user message to the bot in that thread, so it can redo the work. Its new proposal sets `replacesActionId`.
- Holds live in the store. A quit or crash during a hold returns the action to `pending` at the next start. It never runs on its own after a restart.
- A crash during `executing` leaves `unknown`. The core never retries it. The card says "May have run. Check Gmail, then mark it Sent or Retry."

The shell's keys and screens for this are in `docs/DESIGN.md` §2.2-2.4.

## 6. Undo

| Action | Inverse |
|---|---|
| `mail.label` | The opposite op on the same messages |
| `mail.draft` | Delete the draft |
| `calendar.create` (no attendees) | Delete the event |
| `calendar.update` (no attendees) | Apply `before` |
| `mail.send`, anything `outward` | None after the hold |
| pi `write`/`edit` in `workDir` | The core snapshots the file before the call; undo restores it |

`auto` actions with an inverse show in Today's receipts with Undo for 24 hours.

## 7. Never-list

Blocked in every mode, in code, not in the prompt:

- pi `bash` commands that delete the home folder, system folders or `/`, `mkfs`, `dd` to a disk, fork bombs, `sudo`, and writing to `~/Maestro/.agents/` or the state folder. This is a check on the command text, not a sandbox; security.md §5 says what it does not stop.
- File tools outside `workDir` that touch `~/Maestro/.agents/`, the state folder, `~/.ssh`, `~/Library/Keychains`.
- Mail to more than 20 recipients in one action, or more than 50 outward actions per bot per day (both settings).

## 8. Unattended runs

A run whose root cause is a routine, a channel message from someone other than the owner, or mail arriving, is **unattended**: the user did not just ask for it, and its input came from outside.

In unattended runs, `outward`, `destructive` and `exec` are `ask` even if a policy says `auto`. Reads and `own` still run. So a mail-triage routine can label and draft freely, and a prompt-injected email cannot make it send anything.

Every action proposed in a run that has read outside content (mail bodies, web pages, channel messages from others) carries the warning `from_untrusted_content`.
</content>
