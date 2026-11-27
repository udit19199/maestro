-- Maestro store, schema version 1. One SQLite file: maestro.db.
-- Opened with: PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000; PRAGMA synchronous=NORMAL;
-- Times are ISO 8601 UTC text (types/domain.ts Instant). JSON columns hold the shapes named in their comments.

PRAGMA user_version = 1;

CREATE TABLE settings (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL CHECK (json_valid(value))
) STRICT;

-- Load state of bot files. History rows point here, so a deleted file becomes status 'removed'.
CREATE TABLE bots (
  id         TEXT PRIMARY KEY CHECK (id GLOB '[a-z0-9]*' AND length(id) <= 40),
  status     TEXT NOT NULL CHECK (status IN ('active','invalid','removed')),
  file_hash  TEXT,
  loaded     TEXT CHECK (loaded IS NULL OR json_valid(loaded)), -- Bot, as last loaded
  errors     TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(errors)),
  first_seen TEXT NOT NULL,
  updated_at TEXT NOT NULL
) STRICT;

CREATE TABLE threads (
  id               TEXT PRIMARY KEY,
  kind             TEXT NOT NULL CHECK (kind IN ('direct','group','routine','channel','task')),
  title            TEXT NOT NULL,
  audience         TEXT NOT NULL CHECK (audience IN ('private','shared')),
  default_responder TEXT NOT NULL CHECK (json_valid(default_responder)), -- DefaultResponder
  policy           TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(policy)), -- PolicyOverrides
  parent_thread_id TEXT REFERENCES threads(id),
  routine_id       TEXT REFERENCES routines(id),
  last_seq         INTEGER NOT NULL DEFAULT 0,
  last_activity_at TEXT NOT NULL,
  created_at       TEXT NOT NULL,
  archived_at      TEXT,
  CHECK ((kind = 'task') = (parent_thread_id IS NOT NULL)),
  CHECK ((kind = 'routine') = (routine_id IS NOT NULL))
) STRICT;
CREATE INDEX threads_activity ON threads(archived_at, last_activity_at DESC);

CREATE TABLE thread_members (
  thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
  bot_id    TEXT NOT NULL REFERENCES bots(id),
  role      TEXT NOT NULL CHECK (role IN ('lead','member')),
  joined_at TEXT NOT NULL,
  left_at   TEXT,
  PRIMARY KEY (thread_id, bot_id)
) STRICT;
CREATE INDEX thread_members_bot ON thread_members(bot_id) WHERE left_at IS NULL;

CREATE TABLE episodes (
  id          TEXT PRIMARY KEY,
  thread_id   TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
  n           INTEGER NOT NULL,
  open_reason TEXT NOT NULL CHECK (open_reason IN ('first','gap','command','routine_run','user_reset')),
  opened_at   TEXT NOT NULL,
  closed_at   TEXT,
  carry_over  TEXT CHECK (carry_over IS NULL OR length(carry_over) <= 600),
  UNIQUE (thread_id, n)
) STRICT;
-- Invariant 2: at most one open episode per thread.
CREATE UNIQUE INDEX episodes_one_open ON episodes(thread_id) WHERE closed_at IS NULL;

CREATE TABLE sessions (
  id           TEXT PRIMARY KEY, -- also the pi session id
  episode_id   TEXT NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
  thread_id    TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
  bot_id       TEXT NOT NULL REFERENCES bots(id),
  jsonl_path   TEXT NOT NULL,
  seen_seq     INTEGER NOT NULL DEFAULT 0,
  last_used_at TEXT NOT NULL,
  UNIQUE (episode_id, bot_id) -- invariant 1
) STRICT;

CREATE TABLE messages (
  id          TEXT PRIMARY KEY,
  thread_id   TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
  seq         INTEGER NOT NULL,
  episode_id  TEXT NOT NULL REFERENCES episodes(id),
  author      TEXT NOT NULL CHECK (json_valid(author)), -- Author
  author_bot  TEXT GENERATED ALWAYS AS (json_extract(author, '$.botId')) VIRTUAL,
  kind        TEXT NOT NULL CHECK (kind IN ('chat','handoff','handoff_result','action_note','routine_prompt','episode_break')),
  text        TEXT NOT NULL,
  attachments TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(attachments)),
  status      TEXT NOT NULL CHECK (status IN ('complete','streaming','failed','stopped','interrupted')),
  run_id      TEXT REFERENCES runs(id),
  reply_to    TEXT REFERENCES messages(id),
  created_at  TEXT NOT NULL,
  UNIQUE (thread_id, seq) -- invariant 4
) STRICT;

-- Recall (context.md §5). Contentless-delete keeps the index small and lets rows be removed.
CREATE VIRTUAL TABLE messages_fts USING fts5(text, content='', contentless_delete=1, tokenize='unicode61 remove_diacritics 2');

CREATE TABLE runs (
  id                TEXT PRIMARY KEY,
  thread_id         TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
  episode_id        TEXT NOT NULL REFERENCES episodes(id),
  session_id        TEXT NOT NULL REFERENCES sessions(id),
  bot_id            TEXT NOT NULL REFERENCES bots(id),
  cause             TEXT NOT NULL CHECK (json_valid(cause)), -- RunCause
  status            TEXT NOT NULL CHECK (status IN ('queued','running','completed','failed','stopped','interrupted','cancelled')),
  root_run_id       TEXT NOT NULL REFERENCES runs(id),
  hop               INTEGER NOT NULL DEFAULT 0 CHECK (hop BETWEEN 0 AND 4),
  output_message_id TEXT REFERENCES messages(id),
  error             TEXT CHECK (error IS NULL OR json_valid(error)), -- RunError
  usage             TEXT CHECK (usage IS NULL OR json_valid(usage)), -- Usage
  queued_at         TEXT NOT NULL,
  started_at        TEXT,
  ended_at          TEXT
) STRICT;
-- Invariant 3: one running run per session.
CREATE UNIQUE INDEX runs_one_running ON runs(session_id) WHERE status = 'running';
CREATE INDEX runs_queue ON runs(session_id, queued_at) WHERE status = 'queued';
CREATE INDEX runs_root ON runs(root_run_id);

CREATE TABLE tool_calls (
  id             TEXT PRIMARY KEY,
  run_id         TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
  tool           TEXT NOT NULL,
  label          TEXT NOT NULL,
  effect         TEXT NOT NULL CHECK (effect IN ('read','local','own','outward','destructive','exec')),
  status         TEXT NOT NULL CHECK (status IN ('running','ok','error','proposed','blocked')),
  result_summary TEXT,
  action_id      TEXT REFERENCES actions(id),
  started_at     TEXT NOT NULL,
  ended_at       TEXT
) STRICT;
CREATE INDEX tool_calls_run ON tool_calls(run_id);

CREATE TABLE actions (
  id                 TEXT PRIMARY KEY,
  number             INTEGER NOT NULL UNIQUE,
  run_id             TEXT NOT NULL REFERENCES runs(id),
  tool_call_id       TEXT NOT NULL,
  bot_id             TEXT NOT NULL REFERENCES bots(id),
  thread_id          TEXT NOT NULL REFERENCES threads(id),
  effect             TEXT NOT NULL CHECK (effect IN ('read','local','own','outward','destructive','exec')),
  kind               TEXT GENERATED ALWAYS AS (json_extract(payload, '$.kind')) VIRTUAL,
  payload            TEXT NOT NULL CHECK (json_valid(payload)), -- ActionPayload
  edited_payload     TEXT CHECK (edited_payload IS NULL OR json_valid(edited_payload)),
  warnings           TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(warnings)),
  status             TEXT NOT NULL CHECK (status IN ('pending','held','executing','succeeded','failed','unknown','undone','denied','replaced','expired','blocked')),
  decision           TEXT CHECK (decision IN ('auto','approved','denied')),
  note               TEXT,
  replaces_action_id TEXT REFERENCES actions(id),
  hold_until         TEXT,
  result             TEXT CHECK (result IS NULL OR json_valid(result)),
  error              TEXT,
  undo               TEXT CHECK (undo IS NULL OR json_valid(undo)),
  created_at         TEXT NOT NULL,
  decided_at         TEXT,
  executed_at        TEXT,
  -- Invariant 5 (the workspace override is checked in code).
  CHECK (status NOT IN ('executing','succeeded','failed','unknown','undone') OR decision IN ('auto','approved')),
  CHECK (status <> 'held' OR (decision = 'approved' AND hold_until IS NOT NULL))
) STRICT;
CREATE INDEX actions_open ON actions(status, created_at) WHERE status IN ('pending','held','executing');
CREATE INDEX actions_recent ON actions(executed_at DESC) WHERE executed_at IS NOT NULL;

CREATE TABLE handoffs (
  id                TEXT PRIMARY KEY,
  from_run_id       TEXT NOT NULL REFERENCES runs(id),
  from_bot_id       TEXT NOT NULL REFERENCES bots(id),
  to_bot_id         TEXT NOT NULL,
  source_thread_id  TEXT NOT NULL REFERENCES threads(id),
  target_thread_id  TEXT REFERENCES threads(id),
  text              TEXT NOT NULL,
  hop               INTEGER NOT NULL CHECK (hop BETWEEN 1 AND 4),
  status            TEXT NOT NULL CHECK (status IN ('sent','running','answered','blocked')),
  block_reason      TEXT CHECK (block_reason IN ('hop_limit','run_budget','unknown_bot','not_allowed')),
  answer_message_id TEXT REFERENCES messages(id),
  created_at        TEXT NOT NULL
) STRICT;

CREATE TABLE ledger_items (
  id         TEXT PRIMARY KEY,
  bot_id     TEXT NOT NULL REFERENCES bots(id),
  kind       TEXT NOT NULL CHECK (kind IN ('promise','waiting','follow_up','needs_user','proposal')),
  status     TEXT NOT NULL CHECK (status IN ('open','done','dropped')),
  summary    TEXT NOT NULL CHECK (length(summary) <= 140),
  detail     TEXT,
  due_at     TEXT,
  action_id  TEXT REFERENCES actions(id),
  origin_thread_id  TEXT NOT NULL REFERENCES threads(id),
  origin_message_id TEXT REFERENCES messages(id),
  origin_run_id     TEXT REFERENCES runs(id),
  origin_audience   TEXT NOT NULL CHECK (origin_audience IN ('private','shared')),
  created_at TEXT NOT NULL,
  closed_at  TEXT,
  close_note TEXT
) STRICT;
CREATE INDEX ledger_open ON ledger_items(bot_id, due_at) WHERE status = 'open';

CREATE TABLE memory_entries (
  id                TEXT PRIMARY KEY,
  scope_bot_id      TEXT REFERENCES bots(id), -- NULL means workspace scope
  text              TEXT NOT NULL CHECK (length(text) <= 300),
  origin_thread_id  TEXT REFERENCES threads(id), -- NULL when the user wrote it in Settings
  origin_message_id TEXT REFERENCES messages(id),
  origin_run_id     TEXT REFERENCES runs(id),
  origin_audience   TEXT NOT NULL CHECK (origin_audience IN ('private','shared')),
  written_by        TEXT NOT NULL CHECK (json_valid(written_by)),
  revision          INTEGER NOT NULL DEFAULT 1,
  created_at        TEXT NOT NULL,
  updated_at        TEXT NOT NULL,
  removed_at        TEXT
) STRICT;
CREATE INDEX memory_live ON memory_entries(scope_bot_id) WHERE removed_at IS NULL;

-- Every memory change, so any one can be undone.
CREATE TABLE memory_journal (
  seq        INTEGER PRIMARY KEY,
  entry_id   TEXT NOT NULL REFERENCES memory_entries(id),
  op         TEXT NOT NULL CHECK (op IN ('add','update','remove','restore')),
  before     TEXT,
  after      TEXT,
  run_id     TEXT REFERENCES runs(id),
  at         TEXT NOT NULL
) STRICT;

CREATE TABLE routines (
  id           TEXT PRIMARY KEY,
  status       TEXT NOT NULL CHECK (status IN ('active','invalid','removed')),
  enabled      INTEGER NOT NULL DEFAULT 0 CHECK (enabled IN (0,1)),
  file_hash    TEXT,
  loaded       TEXT CHECK (loaded IS NULL OR json_valid(loaded)),
  errors       TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(errors)),
  last_run_at  TEXT,
  next_run_at  TEXT,
  last_outcome TEXT CHECK (last_outcome IN ('ran','missed','skipped_overlap','skipped_disabled','failed'))
) STRICT;
CREATE INDEX routines_due ON routines(next_run_at) WHERE enabled = 1 AND status = 'active';

CREATE TABLE routine_runs (
  id            TEXT PRIMARY KEY,
  routine_id    TEXT NOT NULL REFERENCES routines(id),
  scheduled_for TEXT NOT NULL,
  started_at    TEXT,
  ended_at      TEXT,
  outcome       TEXT CHECK (outcome IN ('ran','missed','skipped_overlap','skipped_disabled','failed')),
  episode_id    TEXT REFERENCES episodes(id),
  UNIQUE (routine_id, scheduled_for) -- a slot fires at most once
) STRICT;

CREATE TABLE connections (
  id          TEXT PRIMARY KEY,
  kind        TEXT NOT NULL CHECK (kind IN ('google','imap','mcp','model_provider')),
  label       TEXT NOT NULL,
  auth        TEXT NOT NULL CHECK (json_valid(auth)), -- ConnectionAuth
  status      TEXT NOT NULL CHECK (status IN ('ok','needs_reconnect','unreachable','error')),
  status_text TEXT,
  secret_ref  TEXT,
  created_at  TEXT NOT NULL
) STRICT;

-- Mail headers cache (connectors.md §3). Bodies are fetched on demand and kept in mail_bodies.
CREATE TABLE mail_messages (
  connection_id TEXT NOT NULL REFERENCES connections(id) ON DELETE CASCADE,
  ref           TEXT NOT NULL, -- Gmail message id, or IMAP "<uidvalidity>:<uid>"
  thread_ref    TEXT NOT NULL,
  rfc_message_id TEXT,
  from_addr     TEXT NOT NULL,
  to_addrs      TEXT NOT NULL CHECK (json_valid(to_addrs)),
  subject       TEXT NOT NULL,
  snippet       TEXT NOT NULL,
  labels        TEXT NOT NULL CHECK (json_valid(labels)),
  unread        INTEGER NOT NULL CHECK (unread IN (0,1)),
  date          TEXT NOT NULL,
  PRIMARY KEY (connection_id, ref)
) STRICT;
CREATE INDEX mail_thread ON mail_messages(connection_id, thread_ref, date);
CREATE INDEX mail_date ON mail_messages(connection_id, date DESC);

CREATE TABLE mail_bodies (
  connection_id TEXT NOT NULL,
  ref           TEXT NOT NULL,
  body_text     TEXT NOT NULL,
  fetched_at    TEXT NOT NULL,
  PRIMARY KEY (connection_id, ref),
  FOREIGN KEY (connection_id, ref) REFERENCES mail_messages(connection_id, ref) ON DELETE CASCADE
) STRICT;

CREATE TABLE sync_cursors (
  connection_id TEXT PRIMARY KEY REFERENCES connections(id) ON DELETE CASCADE,
  cursor        TEXT NOT NULL, -- IMAP "<uidvalidity>:<highestmodseq>"
  synced_at     TEXT NOT NULL
) STRICT;

CREATE TABLE channel_conversations (
  id           TEXT PRIMARY KEY,
  channel      TEXT NOT NULL CHECK (channel IN ('imessage')),
  external_id  TEXT NOT NULL,
  title        TEXT NOT NULL,
  participants TEXT NOT NULL CHECK (json_valid(participants)),
  audience     TEXT NOT NULL CHECK (audience IN ('private','shared')),
  thread_id    TEXT NOT NULL UNIQUE REFERENCES threads(id),
  enabled      INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0,1)),
  UNIQUE (channel, external_id)
) STRICT;

CREATE TABLE channel_messages (
  external_id             TEXT PRIMARY KEY,
  conversation_id         TEXT NOT NULL REFERENCES channel_conversations(id) ON DELETE CASCADE,
  message_id              TEXT NOT NULL REFERENCES messages(id),
  direction               TEXT NOT NULL CHECK (direction IN ('in','out')),
  reply_to_external_id    TEXT,
  created_at              TEXT NOT NULL
) STRICT;
CREATE INDEX channel_messages_msg ON channel_messages(message_id);

CREATE TABLE channel_cursors (
  channel TEXT PRIMARY KEY,
  cursor  TEXT NOT NULL -- Messages: last chat.db message ROWID read
) STRICT;
