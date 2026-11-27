# Storage

## 1. Two stores, two jobs

| Store | Holds | Writer | Why it is separate |
|---|---|---|---|
| `maestro.db` (SQLite, [schema.sql](schema.sql)) | Everything Maestro owns: threads, transcript, runs, actions, ledger, memory, routines state, connections, mail cache, channel links | Core only | Transactions, constraints, FTS, one file to back up |
| `sessions/<session-id>.jsonl` (pi format) | Model context of one session: what the model saw, tool results, compaction summaries | pi, inside the core | pi owns compaction and its format. The model's view is not the user's transcript |

These are not two copies of one thing. The transcript is what the user and bots said, never compacted. The session is what one model saw, compacted and full of tool output. A group thread has one transcript and one session per bot.

Today's app stores each chat twice with the same meaning (current-state.md §1). The new split removes that.

### How they link

- `sessions.jsonl_path` names the file. The core opens it with `SessionManager.open(path)` and creates new ones with `SessionManager.create(cwd, sessionsDir)` (pi `src/core/session-manager.ts:1777-1788`).
- A bot message row is written when the run starts (status `streaming`) and updated once when it ends. Text deltas are not written to SQLite while streaming (operations.md §2 covers what a crash loses).
- If a session file is missing or unreadable, the core starts a new episode for that thread with a carry-over built from the transcript (context.md §7) and logs it. The transcript is never rebuilt from a session file.

## 2. Rules for the SQLite store

- **One connection, one writer.** All writes go through one `Store` object in the core. Reads use the same connection; WAL lets the shell-facing read paths stay fast. `node:sqlite` `DatabaseSync` (assumption A6). Every write is a short synchronous transaction; nothing awaits network or the model inside one.
- **Commit, then emit.** A command handler runs one transaction, collects its events, commits, then hands the events to the bus (invariant 9).
- **JSON columns** hold tagged unions from [types/domain.ts](types/domain.ts). They are validated by the TypeBox schema when written and trusted when read. A generated column pulls out a field when it must be indexed (`messages.author_bot`, `actions.kind`).
- **Strict tables, checks for enums.** Every enum in the types is a `CHECK (... IN ...)` in SQL. A test reads both and fails if they differ (operations.md §5).
- **Counters** (`threads.last_seq`, `actions.number`) are taken inside the same transaction that uses them: `UPDATE threads SET last_seq = last_seq + 1 ... RETURNING last_seq`.
- **No deletes of history** except when the user deletes a thread (cascades) or retention runs (§4).

## 3. Files on disk

```
~/Library/Application Support/Maestro/
  maestro.db, maestro.db-wal, maestro.db-shm
  sessions/<session-id>.jsonl          pi session files
  attachments/<message-id>/<name>      images and files in messages
  agent/                               pi agentDir: settings.json, models.json (no secrets, see connectors.md §6)
  logs/core.log, logs/core.1.log       rotating, 10 MB each, 5 kept
  shell/snapshot.json                  shell-owned: last snapshot for painting at launch
  backups/maestro-<date>.db            daily, 7 kept (operations.md §4)

~/Maestro/                             the workspace (bot-files.md)
```

File modes: folders 0700, files 0600.

## 4. Retention

| Data | Kept |
|---|---|
| Threads, messages, memory, ledger | Until the user deletes them |
| Runs and tool calls | 90 days, then rows go but messages stay (`messages.run_id` set to NULL) |
| Actions | Final ones 90 days; `pending` 7 days, then `expired` |
| Session files | While their episode is open, then 30 days after it closes. A closed episode's carry-over keeps its gist |
| Mail headers | 90 days back from now; bodies 14 days after last read |
| Routine runs | 90 days |
| Memory journal | 180 days |

Retention runs once a day from the scheduler, in small batches so no transaction holds the writer for more than 50 ms.

## 5. Migrations

- `PRAGMA user_version` is the schema version. The core carries an ordered list of migrations, each a SQL file plus an optional TypeScript step, and runs the missing ones inside one transaction at start.
- Before migrating, the core copies the database to `backups/maestro-pre-v<N>.db`.
- A database newer than the core refuses to open, and the shell says so. No down migrations.
- Bot and routine files carry `maestro.version` (bot-files.md §3). A newer version than the core knows marks that file `invalid`, it does not stop the core.

## 6. Search

- `messages_fts` indexes `messages.text` for `chat`, `handoff` and `handoff_result` messages. The row id is the message's SQLite `rowid`. The store keeps it in step in the same transaction as the message write.
- Recall queries (context.md §5) join back to `messages` and `threads` to filter by audience and membership, so the index itself holds no permissions.
- Mail search goes to Gmail (its search is better than ours) and fills the header cache with what it returns.
</content>
