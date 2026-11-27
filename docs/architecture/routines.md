# Routines

A routine is a prompt that runs by itself: on a schedule, or when mail arrives. Example: "Weekdays at 08:00, Mail sweeps the inbox and posts a brief."

## 1. Definition

One file per routine: `~/Maestro/.agents/maestro/routines/<id>.md`. Frontmatter is the setup, the body is the prompt. Format in [types/bot-file.ts](types/bot-file.ts) (`RoutineFile`).

```markdown
---
name: morning-sweep
description: Inbox sweep and brief before work.
maestro:
  version: 1
  bots: [mail, calendar]
  lead: mail
  schedule: { cron: "0 8 * * 1-5", tz: "Asia/Kolkata" }
  catch_up_hours: 3
  notify: imessage
---

Sweep unread mail from the last 24 hours. Label newsletters, draft replies that need one,
flag anything only I can handle, and check today's calendar for clashes. End with a 5-line brief.
```

- Routines arrive **off**. The user turns each on in the app; that state lives in the store (`routines.enabled`), not in the file, so a copied routine never starts by itself.
- One routine has one thread, kind `routine`. Each run is a new episode in it (domain.md §2), so runs do not pile up context, and the carry-over gives each run the gist of the last.

## 2. Schedules

| Kind | Frontmatter | Fires |
|---|---|---|
| `cron` | `{ cron: "0 8 * * 1-5", tz: "Asia/Kolkata" }` | 5-field cron in that zone; DST handled by the zone |
| `every` | `{ every_minutes: 60 }` | Every N minutes from when it was turned on; minimum 15 |
| `at` | `{ at: "2026-12-01T09:00:00+05:30" }` | Once, then turns itself off |
| `mail` | `{ mail: { query: "from:hdfcbank.com is:unread" } }` | When sync finds new mail matching the Gmail query. At most once per 5 minutes; mail that arrives meanwhile is batched into the next run |

## 3. Firing

1. The scheduler keeps one timer for the earliest `next_run_at` across routines, holds, follow-ups and idle checks.
2. At fire time the core inserts a `routine_runs` row with `(routine_id, scheduled_for)`. That pair is unique, so a slot fires at most once even after a crash.
3. If the routine's previous run is still running: outcome `skipped_overlap`.
4. Otherwise it closes the thread's open episode, opens a new one, writes the body as a `routine_prompt` message, and starts runs per the group rules (runtime.md §2) with cause `routine`.
5. When the runs end, the outcome is `ran` (or `failed`), the episode closes with a carry-over, and `next_run_at` is computed.
6. With `notify: imessage`, the lead bot's final message is also sent to the iMessage self-chat (channels.md §6).

## 4. Missed runs

Routines fire only while the app is running and the Mac is awake.

- At start and on wake, the core finds slots between `last_run_at` and now.
- The latest missed slot runs now if it is within `catch_up_hours` (default 6, settings). Older ones are recorded as `missed`, never run.
- So a Mac asleep all night runs the 08:00 sweep once when opened at 09:30, and does not run a 02:00 backup check at 14:00.

## 5. Follow-ups

A ledger item with `kind: follow_up` and `dueAt` is a one-off timer owned by a bot. When it is due, the core starts a run for that bot in the item's origin thread with the item as input ("Follow-up L-33 is due: check if Priya replied"). These runs are unattended (permissions.md §8).

## 6. Unattended rules

Every routine run is unattended: `outward`, `destructive` and `exec` always become proposals (permissions.md §8). The brief can say "3 replies drafted, P-14 to P-16 waiting for you".
</content>
