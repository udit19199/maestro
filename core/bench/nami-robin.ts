// Benchmark: Nami finds open roles, Robin drafts outreach, in one thread.
// Run: node --expose-gc core/bench/nami-robin.ts [--model provider/id] [--roles 3]
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { Core, type RunMetrics } from "../src/core.ts";
import { loadBot } from "../src/bots.ts";

function argValue(flag: string): string | undefined {
  const i = process.argv.indexOf(flag);
  return i >= 0 ? process.argv[i + 1] : undefined;
}

const modelSpec = argValue("--model") ?? "relay/claude-sonnet-5-5";
const roles = Number(argValue("--roles") ?? "3");
const [provider, ...rest] = modelSpec.split("/");
const modelId = rest.join("/");
if (!provider || !modelId) throw new Error(`bad --model ${modelSpec}, want provider/id`);

const iso = new Date().toISOString().replace(/[:.]/g, "-");
const runDir = join(homedir(), "Workspace/local/maestro/bench-2026-11-28", iso);
mkdirSync(join(runDir, "agent"), { recursive: true });

function firecrawlCredits(): number | undefined {
  try {
    const out = execFileSync("firecrawl", ["--status"], { encoding: "utf8", timeout: 15_000 });
    const clean = out.replace(/\x1b\[[0-9;]*m/g, "");
    const m = clean.match(/Credits:\s*([\d,]+)\s*\//);
    return m ? Number(m[1]?.replace(/,/g, "")) : undefined;
  } catch {
    return undefined;
  }
}

const creditsBefore = firecrawlCredits();

const modelsPath = join(homedir(), "Library/Application Support/Maestro/pi/agent/models.json");
const runtime = await ModelRuntime.create({ modelsPath, authPath: join(runDir, "auth.json") });
const model = runtime.getModel(provider, modelId);
if (!model) throw new Error(`model ${modelSpec} not found in runtime`);

const bots = [
  loadBot(new URL("./bots/nami.md", import.meta.url).pathname),
  loadBot(new URL("./bots/robin.md", import.meta.url).pathname),
];
const core = new Core({ runtime, model, bots, runDir });

// Peak RSS sampled every 100 ms.
let peakRss = process.memoryUsage().rss;
const sampler = setInterval(() => {
  peakRss = Math.max(peakRss, process.memoryUsage().rss);
}, 100);

const wallStart = Date.now();
core.post(
  "bench",
  "user",
  `@nami find ${roles} open roles that fit Udit, and have Robin draft an outreach message for each.`,
);

const CAP_MS = 6 * 60 * 1000;
let capped = false;
await Promise.race([
  core.idle("bench"),
  new Promise((resolve) => setTimeout(resolve, CAP_MS)).then(() => {
    if (core.threads.get("bench")?.busy) {
      capped = true;
      for (const st of core.threads.get("bench")?.bots.values() ?? []) {
        void st.session?.abort();
      }
    }
  }),
]);
// After a cap, give aborted runs a moment to settle.
if (capped) await Promise.race([core.idle("bench"), new Promise((r) => setTimeout(r, 10_000))]);
const wallMs = Date.now() - wallStart;
clearInterval(sampler);

const thread = core.threads.get("bench");
const allTools = core.runs.flatMap((r) => r.tools);
const firstHandoff = allTools.find((t) => t.name === "message_bot");
const firstDraftTool = allTools.find((t) => t.name === "save_draft");

// transcript.md: thread messages in order, then runs with their tool calls.
const lines: string[] = ["# Transcript", "", "## Messages", ""];
for (const m of thread?.messages ?? []) {
  lines.push(`### ${m.seq}. ${m.author} — ${new Date(m.at).toISOString()}`, "", m.text, "");
}
lines.push("## Runs", "");
core.runs.forEach((r: RunMetrics, i) => {
  lines.push(
    `### Run ${i + 1} — ${r.bot} (${(((r.endMs ?? wallStart) - r.startMs) / 1000).toFixed(1)}s, ${r.turns} turns)`,
    "",
    "Prompt:",
    "",
    "```",
    r.prompt,
    "```",
    "",
    "Tool calls:",
    "",
  );
  for (const t of r.tools) {
    lines.push(`- ${t.name}(${JSON.stringify(t.args)}) — ${t.ms ?? "?"}ms${t.isError ? " ERROR" : ""}`);
  }
  if (r.finalText) lines.push("", "Final text:", "", r.finalText);
  if (r.error) lines.push("", `ERROR: ${r.error}`);
  lines.push("");
});
writeFileSync(join(runDir, "transcript.md"), `${lines.join("\n")}\n`);

if (globalThis.gc) globalThis.gc();
const endRss = process.memoryUsage().rss;

function botTotals(bot: string) {
  const rs = core.runs.filter((r) => r.bot === bot);
  const usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };
  for (const r of rs) {
    usage.input += r.usage.input;
    usage.output += r.usage.output;
    usage.cacheRead += r.usage.cacheRead;
    usage.cacheWrite += r.usage.cacheWrite;
  }
  return { runs: rs.length, modelMs: rs.reduce((a, r) => a + r.modelMs, 0), usage };
}

const draftCount = core.runs.flatMap((r) => r.tools).filter((t) => t.name === "save_draft" && !t.isError).length;
const metrics = {
  model: modelSpec,
  roles,
  wallMs,
  capped,
  firstHandoffMs: firstHandoff ? firstHandoff.at - wallStart : null,
  firstDraftMs: firstDraftTool ? firstDraftTool.at - wallStart : null,
  drafts: draftCount,
  hops: thread?.hops ?? 0,
  runs: core.runs.map((r) => ({
    bot: r.bot,
    startMs: r.startMs - wallStart,
    endMs: r.endMs ? r.endMs - wallStart : null,
    modelMs: r.modelMs,
    turns: r.turns,
    usage: r.usage,
    tools: r.tools.map((t) => ({ name: t.name, ms: t.ms ?? null, isError: t.isError ?? false })),
    error: r.error ?? null,
  })),
  totals: { nami: botTotals("nami"), robin: botTotals("robin") },
  peakRssMB: +(peakRss / 1048576).toFixed(1),
  endRssMB: +(endRss / 1048576).toFixed(1),
  firecrawlCredits: { before: creditsBefore ?? null, after: firecrawlCredits() ?? null },
};
writeFileSync(join(runDir, "metrics.json"), `${JSON.stringify(metrics, null, 2)}\n`);
console.log(JSON.stringify(metrics, null, 2));
console.error(`run dir: ${runDir}`);
core.dispose();
process.exit(0);
