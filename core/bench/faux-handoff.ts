// Faux-provider test of the hand-off batching in core. No network, no firecrawl.
// Run: node core/bench/faux-handoff.ts
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fauxAssistantMessage, fauxProvider, fauxText, fauxToolCall } from "@earendil-works/pi-ai";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { Core, HOP_LIMIT } from "../src/core.ts";
import type { Bot } from "../src/bots.ts";

const dir = mkdtempSync(join(tmpdir(), "maestro-faux-"));

const faux = fauxProvider({ provider: "faux", models: [{ id: "m", contextWindow: 10_000_000 }], tokensPerSecond: 1e9 });
const runtime = await ModelRuntime.create({ modelsPath: null, authPath: join(dir, "auth.json"), allowModelNetwork: false });
runtime.registerNativeProvider(faux.provider);
await runtime.setRuntimeApiKey("faux", "k");
const model = runtime.getModel("faux", "m");
if (!model) throw new Error("faux model missing");

// Sessions share one response queue, so every step decides from its own context.
const HANDOFF_ONE = "role one at Acme, contact Priya";
const HANDOFF_TWO = "role two at Globex, contact Raj";
type CtxMessage = { role: string; content?: unknown; toolName?: string; sections?: Record<string, string | null> };
function textOf(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) return content.map((c) => (typeof c?.text === "string" ? c.text : "")).join(" ");
  return "";
}
function step(ctx: { messages: CtxMessage[] }) {
  // pi carries the system prompt in the leading system message's named sections.
  const sysMsg = ctx.messages.find((m) => m.role === "system");
  const sys = textOf(sysMsg?.content) + " " + Object.values(sysMsg?.sections ?? {}).join(" ");
  const isRobin = sys.includes("You are Robin");
  const last = ctx.messages.at(-1);
  if (last?.role === "toolResult") {
    return fauxAssistantMessage(fauxText(isRobin ? "Robin done." : "Nami done."));
  }
  if (isRobin) {
    return fauxAssistantMessage(
      [
        fauxToolCall("save_draft", { to: "Priya", channel: "email", role_url: "https://acme.test/1", text: "draft one" }),
        fauxToolCall("save_draft", { to: "Raj", channel: "linkedin", role_url: "https://globex.test/2", text: "draft two" }),
      ],
      { stopReason: "toolUse" },
    );
  }
  return fauxAssistantMessage(
    [
      fauxToolCall("message_bot", { to: "robin", text: HANDOFF_ONE }),
      fauxToolCall("message_bot", { to: "robin", text: HANDOFF_TWO }),
    ],
    { stopReason: "toolUse" },
  );
}
faux.appendResponses(Array.from({ length: 50 }, () => step));

const bots: Bot[] = [
  { id: "nami", description: "finder", tools: ["message_bot"], mcp: {}, instructions: "You are Nami. Hand off to Robin." },
  { id: "robin", description: "drafter", tools: ["save_draft"], mcp: {}, instructions: "You are Robin. Save drafts." },
];
const core = new Core({ runtime, model, bots, runDir: dir });

const t0 = Date.now();
core.post("t1", "user", "@nami find 2 roles and have Robin draft outreach for each.");
await core.idle("t1");

const failures: string[] = [];
function check(label: string, ok: boolean, detail = "") {
  console.log(`${ok ? "PASS" : "FAIL"} ${label}${detail ? ` — ${detail}` : ""}`);
  if (!ok) failures.push(label);
}

const robinRuns = core.runs.filter((r) => r.bot === "robin");
const namiRuns = core.runs.filter((r) => r.bot === "nami");
check("robin ran exactly once", robinRuns.length === 1, `runs: ${robinRuns.length}`);
check("nami ran exactly once", namiRuns.length === 1, `runs: ${namiRuns.length}`);
const firstRobinPrompt = robinRuns[0]?.prompt ?? "";
check(
  "robin's first prompt contains both hand-offs",
  firstRobinPrompt.includes(HANDOFF_ONE) && firstRobinPrompt.includes(HANDOFF_TWO),
);
check("hand-offs formatted as author lines", firstRobinPrompt.includes(`nami: ${HANDOFF_ONE}`));

const drafts = readFileSync(join(dir, "drafts.jsonl"), "utf8").trim().split("\n").map((l) => JSON.parse(l));
check("2 drafts saved", drafts.length === 2, `drafts: ${drafts.length}`);
check("draft numbering", drafts[0]?.n === 1 && drafts[1]?.n === 2);

const thread = core.threads.get("t1");
check("hop count is 2", thread?.hops === 2, `hops: ${thread?.hops}`);

const sessionCount = thread?.bots.get("robin")?.session ? 1 : 0;
check("robin session count is 1", sessionCount === 1);

const messageBotCalls = core.runs.flatMap((r) => r.tools).filter((t) => t.name === "message_bot");
check("two message_bot tool calls", messageBotCalls.length === 2, `calls: ${messageBotCalls.length}`);
check("tool durations recorded", messageBotCalls.every((t) => typeof t.ms === "number"));
check("usage recorded on nami run", (namiRuns[0]?.turns ?? 0) === 2, `turns: ${namiRuns[0]?.turns}`);

// Both hand-off texts are in the thread, authored by nami.
const handoffMsgs = thread?.messages.filter((m) => m.text === HANDOFF_ONE || m.text === HANDOFF_TWO) ?? [];
check("hand-offs posted to thread by nami", handoffMsgs.length === 2 && handoffMsgs.every((m) => m.author === "nami"));

core.dispose();

// ---- Mention-by-reply scenarios: fresh runtime + core per scenario. ----
async function mentionCore(dirX: string, replyStyle: "mention" | "plain") {
  const fauxX = fauxProvider({ provider: "faux", models: [{ id: "m", contextWindow: 10_000_000 }], tokensPerSecond: 1e9 });
  const runtimeX = await ModelRuntime.create({ modelsPath: null, authPath: join(dirX, "auth.json"), allowModelNetwork: false });
  runtimeX.registerNativeProvider(fauxX.provider);
  await runtimeX.setRuntimeApiKey("faux", "k");
  const modelX = runtimeX.getModel("faux", "m");
  if (!modelX) throw new Error("faux model missing");
  function stepX(ctx: { messages: CtxMessage[] }) {
    const sysMsg = ctx.messages.find((m) => m.role === "system");
    const sys = Object.values(sysMsg?.sections ?? {}).join(" ");
    if (sys.includes("You are beta")) return fauxAssistantMessage(fauxText("beta finished"));
    return fauxAssistantMessage(fauxText(replyStyle === "mention" ? "@beta do x" : "no mention here"));
  }
  fauxX.appendResponses(Array.from({ length: 20 }, () => stepX));
  const botsX: Bot[] = [
    { id: "alpha", description: "starter", tools: [], mcp: {}, instructions: "You are alpha." },
    { id: "beta", description: "worker", tools: [], mcp: {}, instructions: "You are beta." },
  ];
  return new Core({ runtime: runtimeX, model: modelX, bots: botsX, runDir: dirX });
}

// (a) alpha's final text "@beta do x" wakes beta with that text in its prompt.
const dirA = mkdtempSync(join(tmpdir(), "maestro-faux-a-"));
const coreA = await mentionCore(dirA, "mention");
coreA.post("t", "user", "@alpha start");
await coreA.idle("t");
const alphaRuns = coreA.runs.filter((r) => r.bot === "alpha");
const betaRuns = coreA.runs.filter((r) => r.bot === "beta");
check("mention: beta ran exactly once", betaRuns.length === 1, `runs: ${betaRuns.length}`);
check("mention: beta prompt carries alpha's reply", (betaRuns[0]?.prompt ?? "").includes("alpha: @beta do x"));
check("mention: hop counted", coreA.threads.get("t")?.hops === 1, `hops: ${coreA.threads.get("t")?.hops}`);
// (c) beta's final text has no mention, so alpha never re-runs.
check("no mention: alpha ran exactly once", alphaRuns.length === 1, `runs: ${alphaRuns.length}`);
coreA.dispose();

// (b) at the hop limit a mention wakes nobody.
const dirB = mkdtempSync(join(tmpdir(), "maestro-faux-b-"));
const coreB = await mentionCore(dirB, "mention");
coreB.thread("t").hops = HOP_LIMIT;
coreB.post("t", "user", "@alpha start");
await coreB.idle("t");
check("hop limit: beta never ran", coreB.runs.filter((r) => r.bot === "beta").length === 0);
coreB.dispose();

// (c2) a final text without a mention wakes nobody even below the limit.
const dirC = mkdtempSync(join(tmpdir(), "maestro-faux-c-"));
const coreC = await mentionCore(dirC, "plain");
coreC.post("t", "user", "@alpha start");
await coreC.idle("t");
check("plain reply: beta never ran", coreC.runs.filter((r) => r.bot === "beta").length === 0);
check("plain reply: no hops", coreC.threads.get("t")?.hops === 0, `hops: ${coreC.threads.get("t")?.hops}`);
coreC.dispose();

console.log(`hop limit constant: ${HOP_LIMIT}; wall ${Date.now() - t0}ms; run dir ${dir}`);
if (failures.length) {
  console.error(`FAILURES: ${failures.join(", ")}`);
  process.exit(1);
}
console.log("ALL PASS");
process.exit(0);
