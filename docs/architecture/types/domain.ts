// Maestro domain types: the shapes the core stores and the protocol carries.
// The core defines these in TypeBox with the same names and fields; this file is the reviewed spec.

// ---------- Identity ----------

type Brand<T, B extends string> = T & { readonly __brand: B };

export type BotId = Brand<string, "BotId">; // file stem, [a-z0-9-]{1,40}
export type RoutineId = Brand<string, "RoutineId">; // file stem
export type ThreadId = Brand<string, "ThreadId">; // thr_<ulid>
export type EpisodeId = Brand<string, "EpisodeId">; // ep_<ulid>
export type SessionId = Brand<string, "SessionId">; // ses_<ulid>, also the pi session id
export type MessageId = Brand<string, "MessageId">; // msg_<ulid>
export type RunId = Brand<string, "RunId">; // run_<ulid>
export type ToolCallId = Brand<string, "ToolCallId">; // pi tool call id
export type ActionId = Brand<string, "ActionId">; // act_<ulid>
export type HandoffId = Brand<string, "HandoffId">; // hof_<ulid>
export type LedgerItemId = Brand<string, "LedgerItemId">; // led_<ulid>
export type MemoryEntryId = Brand<string, "MemoryEntryId">; // mem_<ulid>
export type ConnectionId = Brand<string, "ConnectionId">; // con_<ulid>
export type ChannelConversationId = Brand<string, "ChannelConversationId">; // chc_<ulid>
export type RoutineRunId = Brand<string, "RoutineRunId">; // rr_<ulid>

/** ISO 8601 UTC with milliseconds, e.g. 2026-11-27T08:00:00.000Z. */
export type Instant = Brand<string, "Instant">;

// ---------- Bots and the workspace ----------

export type BotStatus = "active" | "invalid" | "removed";

/** A bot as the core knows it after loading its file. The file format is in bot-file.ts. */
export interface Bot {
  id: BotId;
  displayName: string;
  description: string;
  status: BotStatus;
  /** Load errors when status is "invalid", one line each with the field path. */
  errors: string[];
  model: ModelRef | "default";
  thinking: ThinkingLevel;
  skills: string[];
  mcpServers: string[];
  tools: BotToolSet;
  mentionNames: string[]; // lowercase, without "@"; always includes id
  policy: PolicyOverrides;
  workDir: string; // absolute
  color: string | null; // "#rrggbb"
  fileHash: string; // sha256 of the file, to spot edits
}

export interface ModelRef {
  provider: string; // pi provider id, e.g. "relay", "anthropic"
  model: string; // provider model id
}

export type ThinkingLevel = "off" | "minimal" | "low" | "medium" | "high" | "xhigh";

/** Built-in tool groups a bot may use. Maestro tools (memory, ledger, message_bot) are always on. */
export interface BotToolSet {
  files: boolean; // pi read, write, edit, ls, find, grep inside workDir
  shell: boolean; // pi bash; effect class "exec"
  mail: boolean;
  calendar: boolean;
  messages: boolean; // send iMessage to people other than the owner
  web: boolean; // web search and fetch connectors, when configured
}

// ---------- Threads, episodes, sessions ----------

export type ThreadKind = "direct" | "group" | "routine" | "channel" | "task";

/** "shared" means people other than the owner can read the thread (an iMessage group). */
export type Audience = "private" | "shared";

/** Who answers a group message that mentions nobody. */
export type DefaultResponder = { kind: "lead" } | { kind: "everyone" } | { kind: "last_speaker" };

export interface Thread {
  id: ThreadId;
  kind: ThreadKind;
  title: string;
  audience: Audience;
  members: ThreadMember[];
  defaultResponder: DefaultResponder;
  policy: PolicyOverrides;
  parentThreadId: ThreadId | null; // set for kind "task"
  routineId: RoutineId | null; // set for kind "routine"
  channelConversationId: ChannelConversationId | null; // set for kind "channel"
  lastSeq: number;
  lastActivityAt: Instant;
  createdAt: Instant;
  archivedAt: Instant | null;
}

export interface ThreadMember {
  botId: BotId;
  role: "lead" | "member";
  joinedAt: Instant;
}

export type EpisodeOpenReason = "first" | "gap" | "command" | "routine_run" | "user_reset";

export interface Episode {
  id: EpisodeId;
  threadId: ThreadId;
  n: number; // 1, 2, 3 ... within the thread
  openReason: EpisodeOpenReason;
  openedAt: Instant;
  closedAt: Instant | null;
  /** Written when the episode closes; at most 600 characters. Feeds the next episode (context.md §7). */
  carryOver: string | null;
}

export interface Session {
  id: SessionId;
  episodeId: EpisodeId;
  threadId: ThreadId;
  botId: BotId;
  jsonlPath: string; // relative to the state folder
  /** Highest message seq this bot has been given. Group lines after it are new to the bot. */
  seenSeq: number;
  lastUsedAt: Instant;
}

// ---------- Messages ----------

export type Author =
  | { kind: "user" }
  | { kind: "bot"; botId: BotId }
  | { kind: "person"; handle: string; name: string | null } // someone else in a shared channel thread
  | { kind: "system" };

export type MessageKind =
  | "chat" // ordinary user or bot text
  | "handoff" // a bot's message to another bot
  | "handoff_result" // the answer coming back
  | "action_note" // "P-12 was sent" and similar, written by the core
  | "routine_prompt" // the prompt a routine run starts with
  | "episode_break"; // marks where a new episode starts

export type MessageStatus = "complete" | "streaming" | "failed" | "stopped" | "interrupted";

export interface Message {
  id: MessageId;
  threadId: ThreadId;
  seq: number;
  episodeId: EpisodeId;
  author: Author;
  kind: MessageKind;
  text: string;
  attachments: Attachment[];
  status: MessageStatus;
  runId: RunId | null; // the run that wrote it, for bot messages
  replyTo: MessageId | null;
  createdAt: Instant;
}

export interface Attachment {
  kind: "image" | "file";
  name: string;
  mime: string;
  path: string; // under the state folder's attachments/
  bytes: number;
}

// ---------- Runs and tool calls ----------

export type RunCause =
  | { kind: "user_message"; messageId: MessageId }
  | { kind: "handoff"; handoffId: HandoffId }
  | { kind: "handoff_result"; handoffId: HandoffId }
  | { kind: "routine"; routineRunId: RoutineRunId }
  | { kind: "action_result"; actionId: ActionId } // only when the bot asked to be woken
  | { kind: "channel_message"; messageId: MessageId };

export type RunStatus = "queued" | "running" | "completed" | "failed" | "stopped" | "interrupted" | "cancelled";

export type RunErrorKind = "provider_down" | "provider_auth" | "rate_limited" | "model_error" | "tool_crash" | "context_overflow" | "core_quit";

export interface RunError {
  kind: RunErrorKind;
  text: string;
  retryable: boolean;
}

export interface Run {
  id: RunId;
  threadId: ThreadId;
  episodeId: EpisodeId;
  sessionId: SessionId;
  botId: BotId;
  cause: RunCause;
  status: RunStatus;
  rootRunId: RunId; // itself, unless caused by a hand-off chain
  hop: number; // 0 for a root run
  outputMessageId: MessageId | null;
  error: RunError | null;
  usage: Usage | null;
  queuedAt: Instant;
  startedAt: Instant | null;
  endedAt: Instant | null;
}

export interface Usage {
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
  costUsd: number | null;
}

export type ToolCallStatus = "running" | "ok" | "error" | "proposed" | "blocked";

export interface ToolCall {
  id: ToolCallId;
  runId: RunId;
  tool: string; // pi tool name, e.g. "gmail_send", "mcp__notion__search"
  label: string; // human line from the tool: "Searching mail: unread in inbox"
  effect: EffectClass;
  status: ToolCallStatus;
  resultSummary: string | null; // "23 results"
  actionId: ActionId | null;
  startedAt: Instant;
  endedAt: Instant | null;
}

// ---------- Effects, policy, actions ----------

/**
 * How far a tool call reaches. permissions.md §2 defines each class and lists the tools in it.
 * read: changes nothing. local: changes only Maestro (memory, ledger). own: reversible change to the
 * user's own data (label, archive, draft, event with no guests). outward: other people can see it
 * (send, invite, reply, post). destructive: cannot be undone (permanent delete). exec: arbitrary code.
 */
export type EffectClass = "read" | "local" | "own" | "outward" | "destructive" | "exec";

export type PolicyRule = "auto" | "ask" | "deny";

/** Sparse: a missing class falls through bot → thread → workspace defaults (permissions.md §3). */
export type PolicyOverrides = Partial<Record<EffectClass, PolicyRule>>;

export type ActionStatus =
  | "pending"
  | "held"
  | "executing"
  | "succeeded"
  | "failed"
  | "unknown"
  | "undone"
  | "denied"
  | "replaced"
  | "expired"
  | "blocked";

export type ActionDecision = "auto" | "approved" | "denied" | null;

/** One effect the core can run without a model. Each kind has a typed payload. */
export type ActionPayload =
  | { kind: "mail.send"; connectionId: ConnectionId; draft: MailDraft }
  | { kind: "mail.reply"; connectionId: ConnectionId; threadRef: string; draft: MailDraft }
  | { kind: "mail.draft"; connectionId: ConnectionId; draft: MailDraft }
  | { kind: "mail.label"; connectionId: ConnectionId; op: MailLabelOp; messageRefs: string[]; labels: string[] }
  | { kind: "mail.trash"; connectionId: ConnectionId; messageRefs: string[] }
  | { kind: "calendar.create"; event: CalendarEventInput }
  | { kind: "calendar.update"; eventRef: string; before: Partial<CalendarEventInput>; after: Partial<CalendarEventInput> }
  | { kind: "calendar.delete"; eventRef: string; event: CalendarEventInput }
  | { kind: "calendar.respond"; eventRef: string; response: "accepted" | "declined" | "tentative" }
  | { kind: "messages.send"; to: string[]; text: string } // iMessage to people other than the owner
  | { kind: "mcp.call"; server: string; tool: string; args: unknown }
  | { kind: "shell.exec"; command: string; cwd: string };

export type MailLabelOp = "archive" | "mark_read" | "mark_unread" | "star" | "unstar" | "add_label" | "remove_label";

export interface MailDraft {
  from: string;
  to: string[];
  cc: string[];
  bcc: string[];
  subject: string;
  bodyText: string;
  inReplyTo: string | null; // RFC 5322 Message-ID
}

export interface CalendarEventInput {
  calendar: string; // calendar id
  title: string;
  start: Instant;
  end: Instant;
  allDay: boolean;
  location: string | null;
  notes: string | null;
  attendees: string[]; // emails; non-empty makes create/update "outward"
}

export type ActionWarning =
  | { kind: "new_recipient"; address: string }
  | { kind: "thread_changed"; newerAt: Instant; from: string }
  | { kind: "domain_mismatch"; address: string }
  | { kind: "overlaps"; title: string; start: Instant; end: Instant }
  | { kind: "from_untrusted_content" }; // the run read outside content before proposing

export interface Action {
  id: ActionId;
  number: number; // shown as "P-<number>", unique per workspace
  runId: RunId;
  toolCallId: ToolCallId;
  botId: BotId;
  threadId: ThreadId;
  effect: EffectClass;
  payload: ActionPayload;
  /** The payload the user approved, if they edited it. */
  editedPayload: ActionPayload | null;
  warnings: ActionWarning[];
  status: ActionStatus;
  decision: ActionDecision;
  note: string | null; // the user's deny note
  replacesActionId: ActionId | null;
  holdUntil: Instant | null;
  result: ActionResult | null;
  error: string | null;
  /** Inverse payload, when the connector can undo this effect. */
  undo: ActionPayload | null;
  createdAt: Instant;
  decidedAt: Instant | null;
  executedAt: Instant | null;
}

export interface ActionResult {
  summary: string; // "Sent to priya@acme.com"
  link: string | null; // Gmail or calendar URL
  ref: string | null; // remote id
}

// ---------- Hand-offs ----------

export type HandoffStatus = "sent" | "running" | "answered" | "blocked";
export type HandoffBlockReason = "hop_limit" | "run_budget" | "unknown_bot" | "not_allowed";

export interface Handoff {
  id: HandoffId;
  fromRunId: RunId;
  fromBotId: BotId;
  toBotId: BotId;
  sourceThreadId: ThreadId;
  targetThreadId: ThreadId; // the source thread if the target is a member, else a new task thread
  text: string;
  hop: number; // fromRun.hop + 1
  status: HandoffStatus;
  blockReason: HandoffBlockReason | null;
  answerMessageId: MessageId | null;
  createdAt: Instant;
}

// ---------- Ledger and memory ----------

export type LedgerKind =
  | "promise" // the bot said it would do something
  | "waiting" // the bot waits on someone or something
  | "follow_up" // check again at dueAt
  | "needs_user" // only the user can do this (DESIGN.md "flags")
  | "proposal"; // mirrors a pending action; closed by the core

export type LedgerStatus = "open" | "done" | "dropped";

export interface Provenance {
  threadId: ThreadId;
  messageId: MessageId | null;
  runId: RunId | null;
  audience: Audience; // of the origin thread at write time
}

export interface LedgerItem {
  id: LedgerItemId;
  botId: BotId;
  kind: LedgerKind;
  status: LedgerStatus;
  summary: string; // one line, at most 140 characters
  detail: string | null;
  dueAt: Instant | null;
  actionId: ActionId | null;
  origin: Provenance;
  createdAt: Instant;
  closedAt: Instant | null;
  closeNote: string | null;
}

/** "bot": only this bot sees it. "workspace": every bot sees it (facts about the user). */
export type MemoryScope = { kind: "bot"; botId: BotId } | { kind: "workspace" };

export interface MemoryEntry {
  id: MemoryEntryId;
  scope: MemoryScope;
  text: string; // one fact, at most 300 characters
  origin: Provenance;
  writtenBy: { kind: "bot"; botId: BotId } | { kind: "user" };
  revision: number;
  createdAt: Instant;
  updatedAt: Instant;
  removedAt: Instant | null;
}

// ---------- Routines ----------

export type Schedule =
  | { kind: "cron"; expr: string; tz: string } // 5-field cron, IANA zone
  | { kind: "every"; minutes: number }
  | { kind: "at"; when: Instant }
  | { kind: "mail"; connectionId: ConnectionId | "any"; query: string }; // new mail matching a Gmail query

export type RoutineRunOutcome = "ran" | "missed" | "skipped_overlap" | "skipped_disabled" | "failed";

export interface RoutineState {
  id: RoutineId;
  enabled: boolean;
  threadId: ThreadId | null;
  lastRunAt: Instant | null;
  nextRunAt: Instant | null;
  lastOutcome: RoutineRunOutcome | null;
}

export interface RoutineRun {
  id: RoutineRunId;
  routineId: RoutineId;
  scheduledFor: Instant;
  startedAt: Instant | null;
  endedAt: Instant | null;
  outcome: RoutineRunOutcome | null;
  episodeId: EpisodeId | null;
}

// ---------- Connections and channels ----------

export type ConnectionAuth =
  | { kind: "imap_app_password"; imapHost: string; smtpHost: string }
  | { kind: "mcp"; transport: "stdio" | "http"; oauth: boolean }
  | { kind: "api_key"; provider: string };

export type ConnectionStatus = "ok" | "needs_reconnect" | "unreachable" | "error";

export interface Connection {
  id: ConnectionId;
  kind: "google" | "imap" | "mcp" | "model_provider";
  label: string; // "udit@gmail.com", "notion"
  auth: ConnectionAuth;
  status: ConnectionStatus;
  statusText: string | null;
  /** Keychain account name; the secret itself never leaves the shell except to the core in memory. */
  secretRef: string | null;
  createdAt: Instant;
}

export interface ChannelConversation {
  id: ChannelConversationId;
  channel: "imessage";
  externalId: string; // Messages chat guid
  title: string;
  participants: string[]; // handles other than the owner
  audience: Audience;
  threadId: ThreadId;
  enabled: boolean;
}

export interface ChannelMessage {
  externalId: string; // Messages message guid
  conversationId: ChannelConversationId;
  messageId: MessageId;
  direction: "in" | "out";
  replyToExternalId: string | null;
  createdAt: Instant;
}
