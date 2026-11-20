# Design

Owner: Staff · Maestro design. Rewritten 15 Nov 2026 from `main` at `3444e9b`. The old version is in `docs/DESIGN.md.bak-15-11-2026`. Architecture lives in `docs/ARCHITECTURE.md`; this file describes behaviour and screens, not widgets.

Maestro has one daily use: bots read Udit's Gmail and the Mac's calendars, propose what to do, and do nothing that sends, drafts, labels or changes an event until he approves it. Everything below serves that loop. If a screen or control does not help it, it is cut (section 8).

Marks used in this file:

- **[stack]**: depends on the shell language or toolkit. Section 9 lists them.
- **[core]**: needs something new from the background core. Section 6 is the full list.
- **[lead]**: a design proposal that changes the architecture or product scope. The lead decides.

## 1. Principles

1. **Approval is the product.** The approval queue is the most important thing on screen. It is where Udit's time goes, so it gets the most care: a real preview, keyboard approval, undo.
2. **The keystroke matches the risk.** Reversible changes (labels, archive, calendar) approve with Return. A send approves only with ⌘Return. Nothing irreversible happens on a single key.
3. **Never make him wait for the window.** Everything already known is on screen before the core answers. Only the model's words and mail lookups stream.
4. **Show what the bot is doing, in plain words.** "Searching mail: unread in inbox", not a spinner. "Working..." alone is not allowed.
5. **One place to look.** Anything waiting on him, from any chat, shows in Today and as a count on the menu bar icon. No macOS system notifications (Udit turned those down for ops on 15 Nov 2026).
6. **Show only what works.** A control whose feature is not connected is hidden or shown as a setup step, never as a button that fails.

## 2. The daily flow

Bots: **Mail** (leads, owns Gmail tools) and **Calendar** (owns calendar tools). They hand work to each other with `message_bot`. Both sit in one group chat called the **Desk**. Udit can also open each bot's own chat.

The Desk is one chat per day, titled by date ("Sun 15 Nov"). A new day starts a new Desk chat on first use. This keeps each bot's context short (fast, cheap, less compaction) and makes the sidebar a plain diary. Open approvals and flags carry over because they live in Today, not in the chat.

### 2.1 Morning (about 5 minutes)

1. **He opens Maestro**: clicks the menu bar icon, presses the global shortcut ⌥Space [stack], or switches to the window. The menu bar icon already shows a number if anything waits on him (for example `3`).
2. **He sees Today first.** It paints from the last saved snapshot in one frame, then updates live. Top to bottom: *Waiting for you* (approvals), *Needs you* (mail only he can handle), *Working* (bots running now), *Done today* (receipts). The composer sits at the bottom, addressed to Mail.
3. **He runs the sweep**: ⌘R, or the Sweep button. This sends the saved sweep prompt to Mail in today's Desk. (Whether the sweep also runs on its own at set times is a question for Udit; see section 10.)
4. **The sweep streams into Today's Working row**: "Mail: Searching mail, unread in inbox (23)", then "Reading 6 messages", then "Calendar: Checking Tue 18 Nov". He does not have to watch. Each proposal joins *Waiting for you* as soon as the bot makes it.
5. **The sweep ends with a short reply in the Desk.** Today shows its first line under Done: "Mail: 3 to approve, 2 need you, 14 newsletters to archive."
6. **He clears the queue with the keyboard** (section 2.2). This usually takes seconds per item.
7. **He handles *Needs you* items** (for example "HDFC asks for KYC documents by 30 Nov, only you can upload"). Each has *Open in Gmail* (O) and *Done* (X). Maestro never acts on these.

### 2.2 Approving, editing, denying

The first approval in the queue is open. The rest are one-line rows below it. Focus moves to the queue when Today opens, unless he is typing in the composer.

| Key | Action |
|---|---|
| ↑ ↓ (or K J) | Move between approvals; the selected one opens |
| Return | Approve a reversible change (label, archive, draft, calendar create, update) |
| ⌘Return | Approve a send. Return on a send does nothing and shows the hint "Sending needs ⌘Return" |
| ⌘⌫ | Approve a calendar delete (destructive, so it also needs a modifier) |
| E | Edit: the draft's To, Cc, Subject and Body become editable in place. Esc leaves edit mode. Approving an edited item says "edited" in the receipt |
| D | Deny |
| N | Deny with a note: an inline field opens ("Tell Mail what to change"). Return sends the note to the bot as a new message, so it can redo the work |
| O | Open the source mail in Gmail in the default browser |
| ⌘Z | Undo the last approval while its hold is running (2.3) |

After any decision the item leaves the queue at once (under 50 ms) and the next one opens. The core confirms after that; if the core rejects the decision, the item comes back with the reason.

### 2.3 The hold: undo after approve

An approved change waits before it runs: **10 s for a send, 5 s for everything else**. During the hold the item sits at the top of *Done today* with a countdown and *Undo ⌘Z*. After the hold, it runs and becomes a receipt ("Sent to priya@acme.com, 09:12"). If it fails, the receipt shows the reason and *Retry*.

This makes every approval reversible for a few seconds, without any reverse operation in Gmail or the calendar. If the app quits during a hold, the change does not run: it returns to the queue on next launch.

### 2.4 Several approvals at once

Today, a bot waits inside `confirm` until he answers, so each chat holds at most one approval, and a sweep with five proposals makes him wait for the model between each one. This design asks for **deferred approvals** [lead] [core]:

1. When a bot calls `gmail_send`, `gmail_draft`, `gmail_label` or `calendar_create/update/delete`, the core checks the input, stores a **proposal**, and returns at once to the model: "Proposed as P-12. Udit will approve or deny it later. Do not propose it again."
2. The bot carries on. A sweep finishes in one run and leaves a queue of N proposals.
3. On approve, the core runs the stored call after the hold. No model is involved. The outcome is added to that bot's session as a note, so its next turn knows "P-12 was sent" or "P-12 failed: ...".
4. On deny with a note, the note goes to the bot as a new message. Its new proposal replaces the old one (the old one shows "replaced").
5. Proposals are saved to disk. They survive a restart and a crash.
6. Before running an email reply, the core checks the thread again. If a newer message arrived after the draft was written, the item stays in the queue with a warning: "Priya wrote again at 10:41 after this draft." He decides again.

If the lead keeps blocking `confirm` instead, the same UI still works: the queue just holds at most one item per running chat, and the Working row shows "Waiting for your approval".

### 2.5 During the day

- He types into the composer in Today or any chat. Return sends; Shift-Return adds a line.
- In the Desk, `@` opens a member list. ↑ ↓ choose, Tab or Return insert. Without a mention, Mail answers.
- A hand-off shows as one line in the chat it came from: "Mail → Calendar: Find a 30 minute slot with Priya next Tuesday". Clicking it (or ⌘↓ when selected) opens the target chat at that message. If the target is in the same group, the line is the message itself.
- When a hand-off chain hits the 4-hop limit, a line says so: "Stopped: 4 hand-offs in a row. Calendar was not messaged."

### 2.6 Evening

He opens Today, clears what is left, and closes the window. Maestro stays in the menu bar. Approvals left open stay open; nothing runs without him.

## 3. Screens

There are three screens: **Today**, **Chat** and **Settings**. Plus the menu bar menu and a ⌘K switcher. All in one window with a sidebar.

### 3.1 Window and sidebar

```
┌─────────────────┬──────────────────────────────────────────────────────┐
│ Today         3 │                                                      │
│                 │                (Today, Chat or Settings)             │
│ DESK            │                                                      │
│ Sun 15 Nov    ● │                                                      │
│ Sat 14 Nov      │                                                      │
│ Fri 13 Nov      │                                                      │
│                 │                                                      │
│ BOTS            │                                                      │
│ Mail          ● │                                                      │
│ Calendar      ! │                                                      │
│                 │                                                      │
│ Settings        │                                                      │
└─────────────────┴──────────────────────────────────────────────────────┘
```

- Row marks: a number is approvals waiting in that chat; `●` (pulsing gently) is a bot running; `!` is a failed last run. Nothing else on the row. No previews, no bot-name subtitles.
- Desk days older than 7 collapse under "Older".
- Settings is a sidebar row and shows in the right pane, as before.

### 3.2 Today

```
 Sunday 15 November                                         Sweep ⌘R

 Waiting for you  3
 ┌────────────────────────────────────────────────────────────────────┐
 │ Send email                                                   Mail  │
 │ To       priya@acme.com                                            │
 │ Subject  Re: Interview slot next week                              │
 │ ────────────────────────────────────────────────────────────────── │
 │ Hi Priya,                                                          │
 │ Tuesday 18 Nov at 3 pm works for me. I've added it to my calendar. │
 │ Udit                                                               │
 │ ────────────────────────────────────────────────────────────────── │
 │ Replying to Priya Shah, Sat 14 Nov: "Could you do Tue or Wed..."   │
 │                                                                    │
 │ ⌘↩ Send      E Edit      D Deny      N Deny with note              │
 └────────────────────────────────────────────────────────────────────┘
   Archive 14 newsletters                                 Mail      ↩
   Add "Interview, Acme" Tue 18 Nov 15:00 to 15:45        Calendar  ↩

 Needs you  2
   HDFC Bank: KYC documents due 30 Nov            only you can upload
   Landlord: asks for the October rent receipt    you have the file

 Working
   Mail   Reading 6 messages                                      12s

 Done today  4
   Sending to priya@acme.com in 8s                         Undo ⌘Z
   Archived 9 messages                                       09:02
   Saved draft "Re: Project report"                          08:58

 ┌────────────────────────────────────────────────────────────────────┐
 │ Ask Mail, or @Calendar                                           ↩ │
 └────────────────────────────────────────────────────────────────────┘
```

Each section hides when empty, except *Waiting for you*, which says "Nothing waiting." in one quiet line.

### 3.3 Approval previews by kind

Every preview shows what will happen in his words, never raw JSON or ids. The core sends typed fields (section 6.4); the shell lays them out.

| Kind | Header | Body | Extra safety signals |
|---|---|---|---|
| Send | "Send email" | To, Cc, Subject, full body, the message it replies to (sender, date, first line) | First time he writes to this address. Thread changed since the draft. Recipient domain differs from the thread's |
| Draft | "Save draft" | Same as send | None. Return approves (a draft is reversible) |
| Label | Verb from the change: "Archive 14 messages", "Mark 6 read", "Star 2", "Add label Receipts to 3" | List of subject and sender, first 8, then "and 6 more" (opens the full list) | Any message in the list is unread and from a person rather than a list |
| Calendar create | "Add event" | Title, day, start to end, calendar, location, notes | Overlaps with another event (named) |
| Calendar update | "Change event" | Only the changed fields, old struck through next to new | Overlaps after the change |
| Calendar delete | "Delete event" | The event in full | Approve needs ⌘⌫ |

### 3.4 Chat

```
 Sun 15 Nov  Desk: Mail, Calendar                           Stop ⌘.

   You     Sweep my inbox
   Mail    ⌁ Searched mail: unread in inbox (23)                0.8s
           ⌁ Read 6 messages                                    2.1s
           Mail → Calendar: Is Tue 18 Nov 3 pm free?
   Calendar⌁ Checked Tue 18 Nov                                 0.3s
           Free from 2 pm to 5 pm.
   Mail    Three things to approve, two that need you...
           ┌ Proposed: Send "Re: Interview slot"  Waiting  Review ┐
           └──────────────────────────────────────────────────────┘
 ┌───────────────────────────────────────────────────────────────────┐
 │ Message the Desk, @ to pick a bot                               ↩ │
 └───────────────────────────────────────────────────────────────────┘
```

- Messages are plain rows with the author's name on the left, not speech bubbles. Each bot has a monogram in a stable color, so a group reads at a glance.
- Tool steps are one quiet line each, with time taken. Completed steps fold into "4 steps" after the reply ends; a click expands them.
- A proposal shows in the chat where it was made, as a compact line with its state (Waiting, Approved, Sent, Denied, Replaced). "Review" (or Return when selected) opens it in Today's queue. Approvals are decided in one place.
- Header: chat name, members, and Stop (⌘.) only while running. No bot picker. Delete is in the sidebar's context menu.

### 3.5 Settings

One page, four rows, each with a status and one action:

| Row | Status shown | Action |
|---|---|---|
| Relay | "Running" or "Not answering on 127.0.0.1:8317" | Check again |
| Model | Current model name | Choose (a list from Relay's catalog) |
| Gmail | "Connected as udit19199@gmail.com" or the reason it failed | Change app password |
| Calendar | "Allowed" or "Not allowed" | Open System Settings at Privacy > Calendars |

Changing the model applies to the next run of each chat. It does not stop running chats (today it stops all of them).

### 3.6 Menu bar

Icon with the number of items waiting (approvals plus *Needs you*), or no number. Its menu: the first 5 waiting items (choosing one opens Today with it selected), then Open Maestro, Sweep now, Settings, Quit.

### 3.7 ⌘K switcher

A text field over the window. It matches chat names, bots and actions (Sweep, Settings, Today, New Desk note). Return opens. It is the only navigation that needs no mouse beyond the shortcuts in section 5.

## 4. States

### 4.1 First run and empty

| State | What Today shows |
|---|---|
| Nothing set up | A 4-row setup list (Relay, Model, Gmail, Calendar) in place of the queue. Each row has its status and one action. The composer is disabled with the line "Connect Relay and choose a model to start." |
| Some set up | The same list shows only the rows still missing, above the normal sections. A missing Calendar does not block mail work |
| Set up, no chats yet | "Nothing waiting." plus the Sweep button highlighted, and the composer ready |
| Nothing waiting, nothing running | "Nothing waiting." and *Done today*. No illustration, no tips |
| Chat with no messages | The composer, focused, with the placeholder. Nothing else |

### 4.2 Running

| Phase | Shown in the chat | Shown in Today's Working row | Sidebar |
|---|---|---|---|
| Sent, waiting for the first event | "Thinking" line, immediately (under 50 ms) | "Mail: Thinking" | `●` |
| Thinking for over 3 s | "Thinking 4s" counting, plus the model name | Same | `●` |
| Tool running | "⌁ Searching mail: unread in inbox" with elapsed time | The same line | `●` |
| Writing | Text streams in | "Mail: Writing" | `●` |
| Waiting on a blocking approval (only if 2.4 is not built) | "Waiting for your approval" with Review | Same | number |
| Retrying (pi auto-retry) | "Model error, retrying (2 of 3)" | Same | `●` |
| Compacting context | "Shortening the conversation" | Same | `●` |

### 4.3 Slow model

- **Up to 3 s** with no first word: only the Thinking line.
- **3 to 20 s**: the line counts seconds and names the model ("Thinking 9s, gpt-6.1-sol").
- **Over 20 s with no new event**: the line becomes "The model is slow to answer" with *Stop ⌘.* and *Retry*. Nothing stops by itself.
- **Over 20 s between words mid-reply**: the same message, below the partial text.
- A tool running for a long time is not "slow model". It shows its own elapsed time ("Reading 6 messages, 14s").

### 4.4 Errors

Each error says what failed, in his words, and offers one fix. Red is used only for the failure text itself.

| Error | Where it shows | Text | Fix offered |
|---|---|---|---|
| Relay not answering | Bar at the top of the window | "Relay is not running. Messages will wait until it is back." | Check again. Messages typed now are kept and sent when Relay answers |
| Model error (rate limit, bad model, context too long) | Under the failed reply | "The model refused the request: rate limit." | Retry; Choose another model |
| Gmail login refused | Bar plus the Gmail row in Settings | "Gmail refused the app password." | Open Settings |
| No internet | Bar | "Offline. Mail and model calls will fail until the connection is back." | None; the bar clears itself |
| Calendar not allowed | Calendar step in the chat, and the Settings row | "Maestro is not allowed to read your calendars." | Open System Settings |
| Approved change failed | The receipt in *Done today* | "Could not send: SMTP timed out." | Retry (runs the same stored call; no new approval needed within 1 hour) |
| Bot process crashed | Under the reply | "Mail stopped unexpectedly." | Retry |
| Core crashed | Bar | "Restarting Maestro..." then gone | Automatic, up to 3 times; then "Maestro's core keeps stopping" with Show log |
| Run interrupted by quit | Under the reply on next launch | "Stopped when Maestro quit. This reply is incomplete." | Retry |

### 4.5 Offline

- Today, chats, and the queue stay fully usable from the saved state. He can read, approve and deny while offline.
- Approved changes wait in the hold and then wait for the network; the receipt says "Waiting for connection" and runs when it returns. A send that waited more than 1 hour returns to the queue for a fresh approval instead.
- Sending a message while Relay or the network is down keeps it in the chat with the label "Will send when Relay is back".

## 5. Keyboard

The whole daily flow works without the mouse.

| Where | Key | Action |
|---|---|---|
| Anywhere | ⌥Space [stack] | Show or hide Maestro (global) |
| Anywhere | ⌘1 | Today |
| Anywhere | ⌘2 | Today's Desk |
| Anywhere | ⌘K | Switcher |
| Anywhere | ⌘R | Sweep |
| Anywhere | ⌘, | Settings |
| Anywhere | ⌥⌘↑ ⌥⌘↓ | Previous or next chat in the sidebar |
| Anywhere | ⌘J | Jump to the next item waiting for you, from any screen |
| Anywhere | ⌘L | Focus the composer |
| Anywhere | Esc | Leave the composer (focus goes to the queue in Today, to the message list in a chat) |
| Chat | ⌘. | Stop the running bot |
| Chat | ↑ in an empty composer | Edit the last message he sent (resends it as a new message) |
| Chat | ⌘↓ on a hand-off line | Open the other chat at that message |
| Composer | Return / Shift-Return | Send / new line |
| Composer | @ | Member list (↑ ↓, Tab or Return) |
| Queue | see 2.2 | Approve, edit, deny |
| Today | ⌘Z | Undo during a hold |

Rules:

- Single-letter keys (E, D, N, O, X, J, K) work only when focus is in the queue or the message list, never in a text field.
- Focus never jumps while he is typing. A new approval arriving while the composer has text shows only as the count change.
- Every action reachable by key is shown with its key next to it, in the UI itself (keycaps on the approval card, menu items).
- VoiceOver reads each approval as one item: kind, recipient or event, then the actions.

## 6. What the core must provide

This is the list the lead turns into the core-to-shell protocol. Field names are suggestions.

### 6.1 On connect

- **Snapshot**: chats (id, title, kind `desk|direct|group`, day, members, last activity, waiting count, running, last failed), open proposals, open flags, *Done today* receipts, holds in progress, health (6.2), model.
- The shell saves the last snapshot to disk and paints from it on the next launch before the core answers [stack]. The core's snapshot then corrects anything stale.
- **Chat history** on demand per chat, newest first, in pages (the shell asks for the last 50 messages when a chat opens).

### 6.2 Health

| Event | Fields |
|---|---|
| `relay_status` | `up | down`, last error, checked at |
| `network_status` | `online | offline` |
| `mail_status` | `ok | auth_failed | unreachable | not_set`, address |
| `calendar_status` | `allowed | denied | not_asked` (the shell owns EventKit, so it reports this to the core rather than the other way round) |
| `model` | id, display name |
| `core_restarting` | attempt number |

### 6.3 Chats and runs

| Event | Fields | Shell shows |
|---|---|---|
| `chat_created`, `chat_updated`, `chat_deleted` | as in the snapshot | Sidebar |
| `message_added` | chat, id, author (`user` or bot id), kind `user|bot|handoff|system`, text, time, `via` (for hand-offs: from bot, from chat, hop) | A row |
| `run_started` | chat, run id, bot, cause `user|handoff|sweep`, hop | Thinking line |
| `run_text` | run id, text appended. Batched by the core, at most every 33 ms | Streaming text |
| `tool_started` | run id, call id, tool name, a human label ("Searching mail: unread in inbox"), start time | Tool line |
| `tool_finished` | call id, ok, a short result ("23 results"), duration | Tool line done |
| `run_retrying` | run id, attempt, of, reason | Retrying line |
| `run_compacting` | run id | Compacting line |
| `run_finished` | run id, status `completed|failed|stopped|interrupted`, final text, error kind (`relay_down|model|tool|crash|quit`), error text, retryable | Final state |
| `handoff_blocked` | run id, to, reason `hop_limit|unknown_bot` | Stop line |

The human label for each tool comes from the tool itself (`maestro-pi.ts` knows "search", "read", the query) [core]. The shell never builds sentences from raw arguments.

### 6.4 Proposals (approvals)

| Event | Fields |
|---|---|
| `proposal_created` | id (short, "P-12"), chat, message id, bot, kind `send|draft|label|calendar_create|calendar_update|calendar_delete`, preview (below), warnings (below), created at, `replaces` id |
| `proposal_updated` | id, new preview (after his edit), or new warnings (thread changed) |
| `proposal_held` | id, runs at |
| `proposal_resolved` | id, `approved|denied|replaced|expired`, edited (bool), note |
| `action_finished` | id, ok, result for the receipt ("Sent", Gmail link, event id), error text |

Preview by kind:

- **send, draft**: from, to, cc, subject, body, reply-to (sender, date, first line, Gmail link).
- **label**: verb (`archive|mark_read|mark_unread|star|unstar|add_label|remove_label`), label names, total count, first 8 messages (subject, sender, date, unread).
- **calendar_create**: title, start, end, all-day, calendar name, location, notes.
- **calendar_update**: event id, before (only changed fields), after.
- **calendar_delete**: the full event.

Warnings, each with a plain sentence: `new_recipient`, `thread_changed`, `domain_mismatch`, `includes_unread_from_person`, `overlaps` (with the other event's title and time).

The shell sends:

| Command | Fields |
|---|---|
| `approve` | id, edited preview (optional) |
| `deny` | id, note (optional) |
| `undo` | id (only during the hold) |
| `retry_action` | id |

### 6.5 Flags (mail waiting on him)

A new bot tool, `flag_for_udit`, with no approval because it changes nothing outside Maestro [core] [lead]. It turns "you need to upload your KYC documents" from a sentence buried in a reply into a row he can act on.

| Event | Fields |
|---|---|
| `flag_added` | id, chat, bot, mail (subject, sender, date, Gmail link), why (one line), due date (optional) |
| `flag_resolved` | id, `done|dismissed` |

The shell sends `resolve_flag` (id, done or dismissed).

### 6.6 Other commands from the shell

`send_message` (chat, text), `stop_run` (chat), `retry_run` (chat, message id), `run_sweep`, `open_chat` (marks it seen; the core may warm that chat's session), `set_model`, `delete_chat`, `set_calendar_status`, and the replies to calendar requests (as today, the shell runs EventKit for the core).

### 6.7 What the core must keep on disk

Proposals and their state, flags, receipts for the last 7 days, and holds in progress (so a quit during a hold returns the item to the queue). Runs are not kept: a run cut off by a quit is marked interrupted.

## 7. Perceived performance

Targets are for Udit's Mac (M-series, 24 GB) with Maestro in normal use. Each target has a measurement so build can check it. "Frame" means one display refresh (16.7 ms at 60 Hz, 8.3 ms at 120 Hz).

### 7.1 Must appear at once

| What | Target | How to measure |
|---|---|---|
| Window with Today, from a cold app launch | Content painted under 400 ms | Process start to first frame with the queue drawn (signpost or log timestamps), median of 10 |
| Window from the menu bar, ⌥Space or Dock (app already running) | Under 100 ms | Key event to first frame |
| Switching chat (last 50 messages) | Under 50 ms, no blank frame | Click to frame; screen recording at 120 fps |
| Typed character in the composer | Next frame | Keyboard to screen in Instruments |
| His sent message in the chat | Next frame after Return | Same |
| Thinking line after Return | Under 50 ms | Same |
| Approve, deny, undo: item leaves, next opens | Under 50 ms, before the core confirms | Same |
| Stop: the chat shows stopped | Under 100 ms | Same |
| ⌘K switcher open and filtering | Next frame per key | Same |

### 7.2 Streams

| What | Target |
|---|---|
| First word on screen after Return | Relay's time to first token plus under 150 ms of Maestro overhead. Build measures both parts separately. Today a new chat adds 210 to 460 ms for pi to start (`ARCHITECTURE.md` §2); that must go (a warm session or the single core) |
| Model text | Painted at most once per frame. While streaming a 2,000-word reply into a 200-message chat: no frame over 16.7 ms, and Instruments' hitch time under 5 ms per second |
| Tool lines | Appear when the tool starts, not when it ends |
| Proposals | Join the queue when the bot makes them, not at the end of the run |

Rules for the streaming path [stack]:

- Only the reply that is streaming redraws. The sidebar, Today's other sections and earlier messages do not redraw on each word.
- A long reply is split into blocks (paragraphs, list items). Finished blocks are laid out once; only the open block is laid out again.
- Markdown is drawn for finished blocks. The open block shows plain text until it closes, so formatting never jumps.
- Auto-scroll follows the stream only when he is already at the bottom. If he scrolled up, a "New messages ↓" pill appears and the view stays put.
- Nothing is saved to disk per word. The core owns history; the shell saves only its snapshot, off the main thread, at most every 2 s.

### 7.3 Can wait

These may take time but must show their own progress and never block typing, switching or approving:

- Mail searches and reads (bot tool calls).
- Thread checks before a send runs (2.4, step 6).
- Model catalog in Settings, Relay health checks, Gmail login check.
- Older chat history (loads as he scrolls up, 50 messages a page).
- Overlap checks for calendar proposals (the warning may arrive a moment after the card).

### 7.4 Resource targets

| What | Target |
|---|---|
| CPU at idle, window open, nothing running | Under 1% averaged over 60 s |
| Memory at idle, shell plus core | Under 300 MB |
| Memory with 3 chats used since launch | Under 450 MB |
| Mail tool call (search, 10 results) | Under 1 s on a warm connection |

The memory targets assume the single core (`ARCHITECTURE.md` option B). With one pi process per chat, 3 chats already use about 350 MB in pi alone.

### 7.5 Motion

- An approval leaving the queue: 120 ms slide and fade. The next one opens in 150 ms.
- New proposal joining: 150 ms fade and 4 px rise.
- Running dot: a slow 1.6 s pulse.
- Nothing else moves. With Reduce Motion on, all of it becomes instant.
- Motion never delays an action: the next item takes keys before its animation ends.

## 8. What to cut from today's UI

| Today | Change | Why |
|---|---|---|
| Home: "Choose a bot" buttons | Replace with Today | The daily use starts from what waits on him, not from a bot |
| New Chat sheet (toggle 1 to 6 bots) | Remove. The Desk and each bot's chat exist already; ⌘K reaches them | He does not build groups day to day |
| Bot picker in the chat header (change a chat's bot) | Remove | It restarts sessions and mixes contexts; the daily use has two fixed bots |
| Group member editor in the chat header | Remove from the UI (keep in the core) | Desk members are fixed |
| Settings > Providers (API key and sign-in per provider) | Remove | Relay owns providers. Maestro only picks a model |
| Settings > MCP servers (Notion connect) | Remove [lead] | Notion is not part of the mail and calendar loop. `PRODUCT.md` still lists it; the lead decides |
| "Refresh providers" button | Remove | The model list loads when Settings opens |
| Settings model change stops every chat | Change: applies to the next run | Stopping work for a setting is a surprise |
| Delete Chat button in the chat header | Move to the sidebar context menu | A destructive button next to Stop invites mistakes |
| Sidebar sections Today / Yesterday / Previous 7 Days / Older | Replace with Desk days and Bots | The Desk is already one chat per day |
| Bot name under each sidebar row | Remove | The row name already says it |
| Speech bubbles and the generic bubble icon | Replace with plain rows and bot monograms | Easier to scan in a group |
| "Working..." placeholder | Replace with the Thinking and tool lines (4.2) | It hides what the bot is doing |
| Approval card at the top of the chat with raw `key: value` text | Replace with the queue in Today and typed previews (3.3) | It shows one approval per chat and is hard to read |
| Projects Manager default bot | Replace with Mail and Calendar | It is not part of the daily use |
| Menu bar: Open, New Chat, Settings, Quit | Keep, add the waiting count and items (3.6) | One place to look |

## 9. What depends on the stack

| Item | Why it depends on the stack |
|---|---|
| Global shortcut (⌥Space) | Needs a system hotkey API: Carbon `RegisterEventHotKey` from Swift, a hotkey crate in Rust, a plugin in Tauri |
| Menu bar icon with a number | `NSStatusItem` in Swift; tray title text in Tauri or Rust. A webview tray menu may not take keyboard focus the same way |
| Painting from a saved snapshot under 400 ms cold | Easy in a native shell. A webview shell must also load its engine and bundle; measure it before choosing |
| Streaming text without dropped frames | SwiftUI `Text` re-lays out the whole string; it needs the block split (7.2) or a TextKit view. A webview appends to the DOM cheaply but costs more memory |
| EventKit and the Calendars permission | Needs native code signed as the app (`uditagarwal.maestro`) in any stack; the permission belongs to the app that asks |
| Keyboard focus rules (2.2, 5) | Native focus handling differs between AppKit, SwiftUI and the web; single-letter keys need a focus model the toolkit can enforce |
| VoiceOver | Free with native controls; manual (ARIA) in a webview |
| Network status | `NWPathMonitor` in Swift; a system configuration crate in Rust |
| Gmail app password storage | Today a mode 600 file; Keychain is better and is native in any stack |

## 10. Open question for Udit (sent to the chief of staff)

**Should the sweep run by itself?** Option 1 (recommended): Maestro runs the sweep at 09:00 and 18:00 IST while it is open, so approvals wait for him when he looks. It only reads mail and proposes; nothing runs without approval, and it costs two model runs a day. Option 2: only when he presses ⌘R.

## 11. Look

Native macOS, not branded. System font at system sizes, system colors in light and dark, one accent color (the system accent). Lists and separators instead of cards everywhere; the approval card is the one raised surface on screen, so the eye goes there first. Bot monograms use one stable hue per bot, at low saturation. Keycaps are drawn beside every keyboard action. No illustrations, gradients, emoji or tips.
