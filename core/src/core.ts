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
  // First 500 chars of the error result text, when the call failed.
  error?: string;
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
  declTools?: string[];
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
  declSnapshot?: { name?: string; description?: string }[];
  // Repeat-failure guard, reset per run: exact (name, args) failures seen in this
  // run, the count of consecutive tool errors, and whether the guard aborted.
  failedSigs: Map<string, string>;
  consecutiveErrors: number;
  guardAbort: boolean;
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
  mcpExposure?: "direct" | "codemode" | "hybrid";
};

export class Core {
  readonly runtime: ModelRuntime;
  readonly model: Model<any>;
  readonly bots: Map<string, Bot>;
  readonly runDir: string;
  readonly threads = new Map<string, ThreadState>();
  readonly runs: RunMetrics[] = [];
  readonly mcpServers: Record<string, McpServerConfig>;
  readonly mcpExposure: "direct" | "codemode" | "hybrid";
  private draftCount = 0;
  private readonly draftsPath: string;

  constructor(opts: CoreOptions) {
    this.runtime = opts.runtime;
    this.model = opts.model;
    this.bots = new Map(opts.bots.map((b) => [b.id, b]));
    this.runDir = opts.runDir;
    this.mcpServers = opts.mcpServers ?? {};
    this.mcpExposure = opts.mcpExposure ?? "direct";
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
      // Mentions in a bot's own messages are hand-offs and count against the hop
      // limit; over it, nobody is woken. User mentions are free.
      if (author !== "user" && targets.length > 0) {
        if (t.hops >= HOP_LIMIT) {
          targets = [];
        } else {
          t.hops += targets.length;
        }
      }
    }
    for (const id of targets) this.wake(t, id);
    return msg.seq;
  }

  private botState(t: ThreadState, botId: string): BotThreadState {
    let st = t.bots.get(botId);
    if (!st) {
      st = { seenSeq: 0, phase: "idle", pendingWake: false, toolOrder: new Map(), failedSigs: new Map(), consecutiveErrors: 0, guardAbort: false };
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
    st.failedSigs = new Map();
    st.consecutiveErrors = 0;
    st.guardAbort = false;
    try {
      await session.prompt(prompt);
    } catch (err) {
      run.error = err instanceof Error ? err.message : String(err);
    }
    run.endMs = Date.now();
    run.declBytes = st.declBytes;
    run.declTools = st.declSnapshot?.map((t) => t.name ?? "?");
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
        this.post(t.id, botId, text);
      }
    }
    if (st.guardAbort) run.error = "stopped after 6 failed tool calls in a row";
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

    const ext = (pi: { on: (event: string, handler: (e: unknown) => void) => void }) => {
      pi.on("before_agent_start", (e) => {
        const others = [...this.bots.values()].filter((b) => b.id !== botId);
        let instructions = bot.instructions;
        if (others.length > 0) {
          instructions +=
            "\n\nOther bots in this conversation:\n" +
            others.map((b) => `- ${b.id}: ${b.description}`).join("\n") +
            "\nTo hand work to one, write @<id> in your final reply. They receive your whole reply. Only mention a bot when you want it to act.";
        }
        (e as { systemPromptOptions: { customPrompt: string } }).systemPromptOptions.customPrompt =
          instructions;
      });
      // Repeat-failure guard: an exact (name, args) call that already failed in this
      // run never executes again. pi routes every call — including nested ones a tool
      // makes through ctx.executeTool, e.g. codemode scripts — through this hook.
      pi.on("tool_call", (e) => {
        const ev = e as { toolName: string; input: unknown };
        const sig = `${ev.toolName}:${JSON.stringify(ev.input)}`;
        const firstError = st.failedSigs.get(sig);
        if (firstError !== undefined) {
          return { block: true, reason: `This exact call already failed: ${firstError.slice(0, 300)}. Change the arguments or stop.` };
        }
        return undefined;
      });
      pi.on("before_provider_request", (e) => {
        if (st.declBytes !== undefined) return;
        const payload = (e as { payload?: { tools?: unknown[] } }).payload;
        if (!payload?.tools) return;
        // Byte count is over the raw tool array so it is exact for any provider
        // shape (Anthropic name/input_schema, OpenAI function wrappers, ...).
        st.declBytes = Buffer.byteLength(JSON.stringify(payload.tools));
        st.declSnapshot = payload.tools.map((raw) => {
          const tool = raw as {
            name?: string;
            description?: string;
            function?: { name?: string; description?: string };
          };
          return { name: tool.name ?? tool.function?.name, description: tool.description ?? tool.function?.description };
        });
      });
    };
    const factories: unknown[] = [ext];

    // MCP servers for this bot. Server exposure stays "hidden" and the allow-listed
    // tools override it with "direct", so non-allow-listed tools are unreachable in
    // every mode. In codemode and hybrid the codemode extension then decides how the
    // model sees them: "only" hides the direct declarations and inlines every callable
    // tool's full declaration into the codemode description, "on" keeps the direct
    // declarations and adds a script-call line to each.
    const mcpServerNames = Object.keys(bot.mcp);
    if (mcpServerNames.length > 0) {
      const servers = mcpServerNames.map((name) => {
        const config = this.mcpServers[name];
        if (!config) throw new Error(`bot ${botId}: unknown MCP server "${name}"`);
        const toolExposure = Object.fromEntries((bot.mcp[name] ?? []).map((tool) => [tool, "direct" as const]));
        return {
          name,
          config: { ...config, exposure: "hidden" as const, toolExposure },
          source: "maestro-core",
          scope: "extension" as const,
        };
      });
      factories.push(
        createMcpExtension({
          loadConfig: () => ({ servers, errors: [], autoEnableCodemode: false }),
          logPath: join(this.runDir, "mcp.log"),
        }),
      );
      if (this.mcpExposure !== "direct") {
        factories.push(
          createCodemodeExtension({
            mode: this.mcpExposure === "codemode" ? "only" : "on",
            inlineBudget: Number.MAX_SAFE_INTEGER,
          }),
        );
      }
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
    const toolSelection = mcpServerNames.length > 0
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
    // codemode registers defaultActive: false; nothing else activates it once MCP
    // tools are direct, so activate it explicitly.
    if (mcpServerNames.length > 0 && this.mcpExposure !== "direct") {
      session.setActiveToolsByName([...session.getActiveToolNames(), "codemode"]);
    }

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
          if (ev.isError) {
            const content = (ev.result as { content?: { type: string; text?: string }[] } | undefined)?.content;
            const text = (content ?? []).map((c) => (typeof c?.text === "string" ? c.text : "")).join("\n");
            if (text) rec.error = text.slice(0, 500);
            const sig = `${rec.name}:${JSON.stringify(rec.args)}`;
            if (!st.failedSigs.has(sig)) st.failedSigs.set(sig, (text || "unknown error").slice(0, 500));
            st.consecutiveErrors++;
            if (st.consecutiveErrors >= 6 && !st.guardAbort) {
              st.guardAbort = true;
              void session.abort();
            }
          } else {
            st.consecutiveErrors = 0;
          }
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

