// Core <-> shell wire protocol, version 1. JSON-RPC 2.0, one JSON object per line on the core's stdin/stdout.
// protocol.md explains ordering, errors and batching. Swift Codable types are generated from the JSON Schema of these.

import type {
  Action,
  ActionId,
  ActionPayload,
  Attachment,
  Bot,
  BotId,
  CalendarEventInput,
  Connection,
  ConnectionId,
  ConnectionStatus,
  DefaultResponder,
  Episode,
  Instant,
  LedgerItem,
  LedgerItemId,
  MemoryEntry,
  MemoryEntryId,
  MemoryScope,
  Message,
  MessageId,
  PolicyOverrides,
  RoutineId,
  RoutineRunOutcome,
  RoutineState,
  Run,
  RunError,
  RunId,
  RunStatus,
  Thread,
  ThreadId,
  ThreadKind,
  ToolCall,
  ToolCallId,
  Usage,
} from "./domain.ts";

export const PROTOCOL_VERSION = 1;

// ---------- JSON-RPC envelopes ----------

export interface RpcRequest<M extends string, P> {
  jsonrpc: "2.0";
  id: number; // shell ids are odd, core ids are even, so the two sides never collide
  method: M;
  params: P;
}

export interface RpcNotification<M extends string, P> {
  jsonrpc: "2.0";
  method: M;
  params: P;
}

export type RpcResponse<R> =
  | { jsonrpc: "2.0"; id: number; result: R }
  | { jsonrpc: "2.0"; id: number; error: RpcError };

export interface RpcError {
  code: ErrorCode;
  message: string; // one sentence a user can read
  data?: { field?: string; retryable?: boolean };
}

/** JSON-RPC reserves -32768..-32000; Maestro codes are 1000+. */
export type ErrorCode =
  | -32700 // parse error
  | -32600 // invalid request
  | -32601 // method not found
  | -32602 // invalid params (failed schema check)
  | -32603 // internal error
  | 1001 // not_found
  | 1002 // conflict: the state changed (e.g. action already decided)
  | 1003 // invalid_state: not allowed in the current state
  | 1004 // version_mismatch
  | 1005 // shutting_down
  | 1006; // host_unavailable: the shell cannot do a host request now

// ---------- Shell -> core commands ----------

export interface ShellCommands {
  hello: { params: { protocolVersion: number; shellVersion: string; workspacePath: string; statePath: string; timeZone: string }; result: Snapshot };
  shutdown: { params: Record<string, never>; result: { ok: true } };

  "thread.create": { params: { kind: Extract<ThreadKind, "direct" | "group">; botIds: BotId[]; lead: BotId | null; title: string | null }; result: Thread };
  "thread.update": { params: { threadId: ThreadId; title?: string; addBots?: BotId[]; removeBots?: BotId[]; lead?: BotId; defaultResponder?: DefaultResponder; policy?: PolicyOverrides }; result: Thread };
  "thread.archive": { params: { threadId: ThreadId; archived: boolean }; result: Thread };
  "thread.delete": { params: { threadId: ThreadId }; result: { ok: true } };
  "thread.history": { params: { threadId: ThreadId; beforeSeq: number | null; limit: number }; result: HistoryPage };
  "thread.newEpisode": { params: { threadId: ThreadId }; result: Episode };
  "thread.open": { params: { threadId: ThreadId }; result: { ok: true } }; // marks seen; core may warm sessions

  "message.send": { params: { threadId: ThreadId; text: string; attachments: Attachment[]; clientId: string }; result: { messageId: MessageId; runIds: RunId[] } };
  "run.stop": { params: { runId: RunId }; result: { ok: true } };
  "run.retry": { params: { runId: RunId }; result: { runId: RunId } };

  "action.approve": { params: { actionId: ActionId; editedPayload: ActionPayload | null }; result: Action };
  "action.deny": { params: { actionId: ActionId; note: string | null }; result: Action };
  "action.undo": { params: { actionId: ActionId }; result: Action }; // during hold, or after success if undoable
  "action.retry": { params: { actionId: ActionId }; result: Action };

  "ledger.close": { params: { itemId: LedgerItemId; status: "done" | "dropped"; note: string | null }; result: LedgerItem };
  "memory.list": { params: { scope: MemoryScope }; result: MemoryEntry[] };
  "memory.write": { params: { entryId: MemoryEntryId | null; scope: MemoryScope; text: string }; result: MemoryEntry };
  "memory.remove": { params: { entryId: MemoryEntryId }; result: MemoryEntry };
  "memory.restore": { params: { entryId: MemoryEntryId }; result: MemoryEntry };

  "routine.setEnabled": { params: { routineId: RoutineId; enabled: boolean }; result: RoutineState };
  "routine.runNow": { params: { routineId: RoutineId }; result: { threadId: ThreadId } };

  "connection.imapAdd": { params: { address: string; appPassword: string }; result: Connection };
  "connection.remove": { params: { connectionId: ConnectionId }; result: { ok: true } };

  "host.status": { params: Pick<Health, "network" | "calendarAccess" | "messagesAccess">; result: { ok: true } }; // shell reports Mac-side state when it changes
  "settings.set": { params: { patch: Partial<WorkspaceSettings> }; result: WorkspaceSettings };
  "search.messages": { params: { query: string; limit: number }; result: SearchHit[] };
}

export type ShellCommandName = keyof ShellCommands;

// ---------- Snapshot ----------

export interface Snapshot {
  protocolVersion: number;
  coreVersion: string;
  seq: number; // events after this seq follow
  settings: WorkspaceSettings;
  bots: Bot[];
  threads: ThreadSummary[];
  openActions: Action[]; // pending, held, executing, unknown
  recentReceipts: Action[]; // final, last 24 h
  ledger: LedgerItem[]; // open items of every bot
  runs: RunSummary[]; // queued and running
  routines: RoutineView[];
  connections: Connection[];
  health: Health;
}

export interface ThreadSummary {
  thread: Thread;
  lastMessage: { author: Message["author"]; text: string; at: Instant } | null; // text cut to 200 chars
  unread: number;
  waitingActions: number;
  running: boolean;
}

export interface HistoryPage {
  messages: Message[]; // ascending seq
  toolCalls: ToolCall[]; // for the runs in this page
  hasMore: boolean;
}

export interface RunSummary {
  run: Run;
  textSoFar: string;
  activeTool: { id: ToolCallId; label: string } | null;
}

export interface RoutineView {
  state: RoutineState;
  title: string;
  scheduleText: string; // "Weekdays at 08:00"
  errors: string[];
}

export interface WorkspaceSettings {
  defaultModel: { provider: string; model: string } | null;
  policy: PolicyOverrides; // workspace defaults (permissions.md §3)
  holdSeconds: { send: number; other: number };
  channelEpisodeGapMinutes: number;
  routineCatchUpHours: number;
}

export interface Health {
  model: { status: "ok" | "down" | "auth_failed" | "not_set"; provider: string | null; text: string | null };
  connections: { id: ConnectionId; status: ConnectionStatus }[];
  calendarAccess: "allowed" | "denied" | "not_asked";
  messagesAccess: "allowed" | "denied" | "not_asked";
  network: "online" | "offline";
}

export interface SearchHit {
  threadId: ThreadId;
  messageId: MessageId;
  seq: number;
  snippet: string;
  at: Instant;
}

// ---------- Core -> shell events ----------

export interface EventEnvelope {
  seq: number; // +1 per event within one core process
  at: Instant;
  event: CoreEvent;
}

export type CoreEvent =
  | { type: "bots.changed"; bots: Bot[] }
  | { type: "thread.upserted"; summary: ThreadSummary }
  | { type: "thread.deleted"; threadId: ThreadId }
  | { type: "message.added"; message: Message }
  | { type: "message.updated"; message: Message }
  | { type: "run.queued"; run: Run }
  | { type: "run.started"; runId: RunId; threadId: ThreadId; botId: BotId; startedAt: Instant }
  | { type: "run.text"; runId: RunId; delta: string } // batched, at most every 33 ms per run
  | { type: "run.tool"; runId: RunId; call: ToolCall } // sent on start and on end of each call
  | { type: "run.status"; runId: RunId; status: "retrying" | "compacting" | "waiting_tool"; detail: string | null }
  | { type: "run.ended"; runId: RunId; status: Exclude<RunStatus, "queued" | "running">; error: RunError | null; usage: Usage | null; messageId: MessageId | null }
  | { type: "action.upserted"; action: Action }
  | { type: "ledger.upserted"; item: LedgerItem }
  | { type: "memory.upserted"; entry: MemoryEntry }
  | { type: "routine.upserted"; routine: RoutineView }
  | { type: "routine.fired"; routineId: RoutineId; outcome: RoutineRunOutcome; threadId: ThreadId | null }
  | { type: "connection.upserted"; connection: Connection }
  | { type: "health.changed"; health: Health }
  | { type: "workspace.fileError"; path: string; errors: string[] }
  | { type: "notice"; level: "info" | "warning" | "error"; text: string };

// ---------- Core -> shell host requests ----------

/** Things only the app bundle may do on macOS. The shell answers each, or fails with 1006. */
export interface HostRequests {
  "keychain.get": { params: { account: string }; result: { secret: string | null } };
  "keychain.set": { params: { account: string; secret: string }; result: { ok: true } };
  "keychain.delete": { params: { account: string }; result: { ok: true } };

  "browser.open": { params: { url: string }; result: { ok: true } };

  "calendar.list": { params: Record<string, never>; result: { calendars: { id: string; title: string; writable: boolean }[] } };
  "calendar.events": { params: { from: Instant; to: Instant; calendars: string[] | null }; result: { events: (CalendarEventInput & { ref: string })[] } };
  "calendar.apply": { params: { payload: Extract<ActionPayload, { kind: `calendar.${string}` }> }; result: { ref: string | null } };

  "messages.send": { params: { chatExternalId: string | null; to: string[]; text: string }; result: { externalId: string | null } };

  "notify": { params: { title: string; body: string; threadId: ThreadId | null }; result: { ok: true } };
}

export type HostRequestName = keyof HostRequests;
