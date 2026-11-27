import { appendFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import {
  createAgentSession,
  createCodemodeExtension,
  createMcpExtension,
  DefaultResourceLoader,
  SessionManager,
  SettingsManager,
  type AgentSession,
  type ModelRuntime,
  type McpServerConfig,
} from "@earendil-works/pi-coding-agent";
import type { Model } from "@earendil-works/pi-ai/compat";
import type { Bot } from "./bots.ts";
import { createTools } from "./tools.ts";

export type ThreadMessage = {
  seq: number;
  author: string; // "user" or a bot id
  text: string;
  at: number;
};

export type ToolCallMetrics = {
  name: string;
  args: unknown;
  at: number;
  ms?: number;
  isError?: boolean;
};

export type TurnUsage = {
  input: number;
  output: number;
  cacheRead: number;
  cacheWrite: number;
  ms: number;
};

export type RunMetrics = {
  bot: string;
  threadId: string;
  startMs: number;
  endMs?: number;
  modelMs: number;
  turns: number;
  usage: { input: number; output: number; cacheRead: number; cacheWrite: number };
  turnUsage: TurnUsage[];
  tools: ToolCallMetrics[];
  prompt: string;
  finalText?: string;
  error?: string;
  // Bytes of tool declarations (JSON of name+description+parameters) sent with
  // the session's first request. Set on the first run of the session.
  declBytes?: number;
};

export const HOP_LIMIT = 8;

type BotThreadState = {
  seenSeq: number;
  phase: "idle" | "scheduled" | "running";
  pendingWake: boolean;
  session?: AgentSession;
  sessionPromise?: Promise<AgentSession>;
  currentRun?: RunMetrics;
  toolOrder: Map<string, ToolCallMetrics>;
  declBytes?: number;
};

type ThreadState = {
  id: string;
  messages: ThreadMessage[];
  lastSeq: number;
  busy: number;
  hops: number;
  waiters: (() => void)[];
  bots: Map<string, BotThreadState>;
};

export type CoreOptions = {
  runtime: ModelRuntime;
  model: Model<any>;
  bots: Bot[];
  runDir: string;
  mcpServers?: Record<string, McpServerConfig>;
  mcpExposure?: "direct" | "codemode";
  // server -> tool names exposed; every other tool of that server stays hidden.
  mcpAllow?: Record<string, string[]>;
};

export class Core {
  readonly runtime: ModelRuntime;
  readonly model: Model<any>;
  readonly bots: Map<string, Bot>;
  readonly runDir: string;
  readonly threads = new Map<string, ThreadState>();
  readonly runs: RunMetrics[] = [];
  readonly mcpServers: Record<string, McpServerConfig>;
  readonly mcpExposure: "direct" | "codemode";
  readonly mcpAllow: Record<string, string[]>;
  private draftCount = 0;
  private readonly draftsPath: string;

  constructor(opts: CoreOptions) {
    this.runtime = opts.runtime;
    this.model = opts.model;
    this.bots = new Map(opts.bots.map((b) => [b.id, b]));
    this.runDir = opts.runDir;
    this.mcpServers = opts.mcpServers ?? {};
    this.mcpExposure = opts.mcpExposure ?? "direct";
    this.mcpAllow = opts.mcpAllow ?? {};
    this.draftsPath = join(opts.runDir, "drafts.jsonl");
    mkdirSync(opts.runDir, { recursive: true });
  }

  thread(id: string): ThreadState {
    let t = this.threads.get(id);
    if (!t) {
      t = { id, messages: [], lastSeq: 0, busy: 0, hops: 0, waiters: [], bots: new Map() };
      this.threads.set(id, t);
    }
    return t;
  }

  // Append a message and wake the bots it addresses. Returns the message seq.
  post(
    threadId: string,
    author: string,
    text: string,
    opts: { noMentions?: boolean; wake?: string[] } = {},
  ): number {
    const t = this.thread(threadId);
    const msg: ThreadMessage = { seq: ++t.lastSeq, author, text, at: Date.now() };
    t.messages.push(msg);
    let targets: string[];
    if (opts.wake) {
      targets = opts.wake;
    } else if (opts.noMentions) {
      targets = [];
    } else {
      targets = [...this.bots.keys()].filter(
        (id) => id !== author && new RegExp(`@${id}\\b`, "i").test(text),
      );
    }
    for (const id of targets) this.wake(t, id);
    return msg.seq;
  }

  private botState(t: ThreadState, botId: string): BotThreadState {
    let st = t.bots.get(botId);
    if (!st) {
      st = { seenSeq: 0, phase: "idle", pendingWake: false, toolOrder: new Map() };
      t.bots.set(botId, st);
    }
    return st;
  }

  private wake(t: ThreadState, botId: string): void {
    if (!this.bots.has(botId)) return;
    const st = this.botState(t, botId);
    // A wake during a run asks for exactly one more run when the current one
    // ends; its prompt is every thread message the bot has not seen yet, so
    // hand-offs that arrive during a run batch into a single follow-up run.
    if (st.phase === "running") {
      st.pendingWake = true;
      return;
    }
    if (st.phase === "scheduled") return; // the imminent run picks up everything posted so far
    st.phase = "scheduled";
    t.busy++;
    // Defer to a macrotask so hand-offs posted back to back in one model turn
    // (their tool executions chain through microtasks only) batch into one prompt.
    setImmediate(() => {
      void this.runLoop(t, st, botId);
    });
  }

  private async runLoop(t: ThreadState, st: BotThreadState, botId: string): Promise<void> {
    st.phase = "running";
    try {
      const session = await this.getSession(t, st, botId);
      for (;;) {
        const unseen = t.messages.filter((m) => m.seq > st.seenSeq && m.author !== botId);
        if (unseen.length === 0) break;
        st.pendingWake = false;
        st.seenSeq = t.lastSeq;
        const prompt = unseen.map((m) => `${m.author}: ${m.text}`).join("\n");
        await this.runOnce(t, st, botId, session, prompt);
        if (!st.pendingWake) break;
      }
    } catch (err) {
      const run = st.currentRun;
      if (run) run.error = err instanceof Error ? err.message : String(err);
    } finally {
      st.currentRun = undefined;
      st.phase = "idle";
      t.busy--;
      if (t.busy === 0) {
        const waiters = t.waiters.splice(0);
        for (const resolve of waiters) resolve();
      }
    }
  }

  private async runOnce(
    t: ThreadState,
    st: BotThreadState,
    botId: string,
    session: AgentSession,
    prompt: string,
  ): Promise<void> {
    const run: RunMetrics = {
      bot: botId,
      threadId: t.id,
      startMs: Date.now(),
      modelMs: 0,
      turns: 0,
      usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      turnUsage: [],
      tools: [],
      prompt,
    };
    this.runs.push(run);
    st.currentRun = run;
    st.toolOrder = new Map();
    try {
      await session.prompt(prompt);
    } catch (err) {
      run.error = err instanceof Error ? err.message : String(err);
    }
    run.endMs = Date.now();
    if (st.declBytes === undefined) {
      st.declBytes = declarationBytes(session);
      run.declBytes = st.declBytes;
    }
    const last = session.messages.findLast((m) => m.role === "assistant");
    if (last && last.role === "assistant") {
      if (last.stopReason === "error") run.error = last.errorMessage ?? "model error";
      const text = last.content
        .filter((c): c is { type: "text"; text: string } => c.type === "text")
        .map((c) => c.text)
        .join("\n")
        .trim();
      if (text && !run.error) {
        run.finalText = text;
        this.post(t.id, botId, text, { noMentions: true });
      }
    }
  }

  private async getSession(t: ThreadState, st: BotThreadState, botId: string): Promise<AgentSession> {
    if (st.session) return st.session;
    st.sessionPromise ??= this.createSession(t, botId);
    const session = await st.sessionPromise;
    st.session = session;
    return session;
  }

  private async createSession(t: ThreadState, botId: string): Promise<AgentSession> {
    const bot = this.bots.get(botId);
    if (!bot) throw new Error(`unknown bot: ${botId}`);
    const st = this.botState(t, botId);
    const cwd = this.runDir;
    const agentDir = join(this.runDir, "agent");
    mkdirSync(agentDir, { recursive: true });

    const ext = (pi: { on: (event: string, handler: (e: unknown) => void) => void }) =>
      pi.on("before_agent_start", (e) => {
        (e as { systemPromptOptions: { customPrompt: string } }).systemPromptOptions.customPrompt =
          bot.instructions;
      });
    const factories: unknown[] = [ext];

    // MCP servers for this bot. Server exposure stays "hidden" and the allow-listed
    // tools override it with the bench's exposure, so everything else is unreachable.
    if (bot.mcp.length > 0) {
      const servers = bot.mcp.map((name) => {
        const config = this.mcpServers[name];
        if (!config) throw new Error(`bot ${botId}: unknown MCP server "${name}"`);
        const allowed = this.mcpAllow[name] ?? [];
        const toolExposure = Object.fromEntries(allowed.map((tool) => [tool, this.mcpExposure]));
        return {
          name,
          config: { ...config, exposure: "hidden" as const, toolExposure },
          source: "maestro-core",
          scope: "extension" as const,
        };
      });
      factories.push(
        createMcpExtension({
          loadConfig: () => ({ servers, errors: [], autoEnableCodemode: this.mcpExposure === "codemode" }),
          logPath: join(this.runDir, "mcp.log"),
        }),
      );
      if (this.mcpExposure === "codemode") factories.push(createCodemodeExtension());
    }

    const resourceLoader = new DefaultResourceLoader({
      cwd,
      agentDir,
      extensionFactories: factories as never[],
      noSkills: true,
      noContextFiles: true,
      noPromptTemplates: true,
    });
    await resourceLoader.reload();

    const host = {
      botIds: () => [...this.bots.keys()],
      sendHandoff: (to: string, text: string): string | undefined => {
        if (!this.bots.has(to)) {
          return `Unknown bot "${to}". Known bots: ${[...this.bots.keys()].join(", ")}.`;
        }
        if (t.hops >= HOP_LIMIT) {
          return `Hop limit reached (${HOP_LIMIT} hand-offs in this thread). Answer with what you have.`;
        }
        t.hops++;
        this.post(t.id, botId, text, { noMentions: true, wake: [to] });
        return undefined;
      },
      saveDraft: (draft: { to: string; channel: "email" | "linkedin"; role_url: string; text: string }): number => {
        const n = ++this.draftCount;
        appendFileSync(this.draftsPath, `${JSON.stringify({ n, ...draft, at: new Date().toISOString() })}\n`);
        return n;
      },
    };
    const customTools = createTools(bot.tools, host);

    // Built-in tools pi activates by default; a bot keeps the ones it lists.
    const BUILT_INS = ["read", "bash", "edit", "write", "ls", "grep", "find", "powershell"];
    const toolSelection = bot.mcp.length > 0
      // An empty allowlist disables MCP tools too, so MCP bots use a denylist instead.
      ? { excludeTools: BUILT_INS.filter((name) => !bot.tools.includes(name)) }
      : { tools: bot.tools };

    const { session } = await createAgentSession({
      cwd,
      agentDir,
      model: this.model,
      thinkingLevel: "off",
      modelRuntime: this.runtime,
      resourceLoader,
      ...toolSelection,
      customTools,
      sessionManager: SessionManager.inMemory(cwd),
      settingsManager: SettingsManager.inMemory({ compaction: { enabled: false } }),
    });
    await session.bindExtensions({});

    session.subscribe((ev) => {
      const run = st.currentRun;
      if (!run) return;
      if (ev.type === "tool_execution_start") {
        const rec: ToolCallMetrics = { name: ev.toolName, args: ev.args, at: Date.now() };
        st.toolOrder.set(ev.toolCallId, rec);
        run.tools.push(rec);
      } else if (ev.type === "tool_execution_end") {
        const rec = st.toolOrder.get(ev.toolCallId);
        if (rec) {
          rec.ms = ev.durationMs;
          rec.isError = ev.isError;
        }
      } else if (ev.type === "turn_end") {
        const msg = ev.message;
        if (msg.role === "assistant") {
          run.turns++;
          run.modelMs += msg.durationMs ?? 0;
          run.usage.input += msg.usage.input;
          run.usage.output += msg.usage.output;
          run.usage.cacheRead += msg.usage.cacheRead;
          run.usage.cacheWrite += msg.usage.cacheWrite;
          run.turnUsage.push({
            input: msg.usage.input,
            output: msg.usage.output,
            cacheRead: msg.usage.cacheRead,
            cacheWrite: msg.usage.cacheWrite,
            ms: msg.durationMs ?? 0,
          });
        }
      }
    });
    return session;
  }

  // Resolves when no run is active or queued for the thread.
  idle(threadId: string): Promise<void> {
    const t = this.thread(threadId);
    if (t.busy === 0) return Promise.resolve();
    return new Promise((resolve) => t.waiters.push(resolve));
  }

  dispose(): void {
    for (const t of this.threads.values()) {
      for (const st of t.bots.values()) {
        st.session?.dispose();
      }
    }
  }
}

// Sum of the JSON sizes of the tool declarations (name+description+parameters)
// carried by the first system message that declares tools.
function declarationBytes(session: AgentSession): number {
  for (const m of session.messages) {
    if (m.role === "system" && m.toolsAdded) {
      let bytes = 0;
      for (const tool of m.toolsAdded) {
        bytes += Buffer.byteLength(JSON.stringify({
          name: tool.name,
          description: tool.description,
          parameters: tool.parameters,
        }));
      }
      return bytes;
    }
  }
  return 0;
}
