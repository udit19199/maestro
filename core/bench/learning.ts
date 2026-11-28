// Benchmark: Nami reads job postings, hands skill gaps to Jinbei, who builds a
// learning-plan scene in Excalidraw+ over MCP. Compares direct vs codemode exposure.
// Run: node --expose-gc core/bench/learning.ts --mode direct|codemode|hybrid [--model provider/id]
import { cpSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { Core, type RunMetrics } from "../src/core.ts";
import { loadBot } from "../src/bots.ts";

const ALLOWED_EXCALIDRAW_TOOLS = [
  "list_collections",
  "list_collection_scenes",
  "create_collection_scene",
  "create_scene",
  "get_scene",
  "get_scene_content",
  "edit_scene_content",
  "read_diagram_format",
  "create_diagram",
  "create_mermaid_diagram",
  "create_table",
  "create_sticky_notes",
  "check_scene_layout",
  "take_screenshot",
];

function argValue(flag: string): string | undefined {
  const i = process.argv.indexOf(flag);
  return i >= 0 ? process.argv[i + 1] : undefined;
}

const mode = argValue("--mode");
if (mode !== "direct" && mode !== "codemode" && mode !== "hybrid") throw new Error("want --mode direct|codemode|hybrid");
const modelSpec = argValue("--model") ?? "relay/claude-sonnet-5-5";
const [provider, ...rest] = modelSpec.split("/");
const modelId = rest.join("/");
if (!provider || !modelId) throw new Error(`bad --model ${modelSpec}, want provider/id`);

// The Excalidraw+ token lives in memory only. Never print, log or write it.
const creds = JSON.parse(readFileSync(join(homedir(), ".config/excalidraw-cli/credentials.json"), "utf8")) as {
  origins: Record<string, { accessToken: string }>;
};
const token = creds.origins["https://api.excalidraw.com"]?.accessToken;
if (!token) throw new Error("no excalidraw token; run `excalidraw login`");

const iso = new Date().toISOString().replace(/[:.]/g, "-");
const runDir = join(homedir(), `Workspace/local/maestro/bench-2026-11-28/learning-${mode}-${iso}`);
mkdirSync(join(runDir, "agent"), { recursive: true });
// Nami's read tool resolves against the session cwd, which is the run dir.
cpSync(new URL("./learning/jobs", import.meta.url).pathname, join(runDir, "jobs"), { recursive: true });

const modelsPath = join(homedir(), "Library/Application Support/Maestro/pi/agent/models.json");
const runtime = await ModelRuntime.create({ modelsPath, authPath: join(runDir, "auth.json") });
const model = runtime.getModel(provider, modelId);
if (!model) throw new Error(`model ${modelSpec} not found in runtime`);

const bots = [
  loadBot(new URL("./learning/nami.md", import.meta.url).pathname),
  loadBot(new URL("./learning/jinbei.md", import.meta.url).pathname),
];
const core = new Core({
  runtime,
  model,
  bots,
  runDir,
  mcpServers: {
    excalidraw: {
      type: "http",
      url: "https://api.excalidraw.com/api/v1/mcp",
      headers: { Authorization: `Bearer ${token}` },
    },
  },
  mcpExposure: mode,
  mcpAllow: { excalidraw: ALLOWED_EXCALIDRAW_TOOLS },
});

let peakRss = process.memoryUsage().rss;
const sampler = setInterval(() => {
  peakRss = Math.max(peakRss, process.memoryUsage().rss);
}, 100);

const wallStart = Date.now();
core.post(
  "bench",
  "user",
  `@nami Read jobs/elip.md and jobs/plansom.md and hand Jinbei the skill gaps. Jinbei: title the board "Maestro bench: learning plan (${mode})".`,
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
if (capped) await Promise.race([core.idle("bench"), new Promise((r) => setTimeout(r, 10_000))]);
const wallMs = Date.now() - wallStart;
clearInterval(sampler);

const thread = core.threads.get("bench");
const allTools = core.runs.flatMap((r) => r.tools);
const firstHandoff = allTools.find((t) => t.name === "message_bot");
const jinbeiRuns = core.runs.filter((r) => r.bot === "jinbei");
const jinbeiFinal = jinbeiRuns.at(-1)?.endMs;
const firstMcpCall = allTools.find((t) => t.name.includes("excalidraw") || t.name.startsWith("mcp__"));

// transcript.md
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
    const args = JSON.stringify(t.args);
    const cut = args.length > 500 ? `${args.slice(0, 500)}…` : args;
    lines.push(`- ${t.name}(${cut}) — ${t.ms ?? "?"}ms${t.isError ? " ERROR" : ""}`);
  }
  if (r.finalText) lines.push("", "Final text:", "", r.finalText);
  if (r.error) lines.push("", `ERROR: ${r.error}`);
  lines.push("");
});
writeFileSync(join(runDir, "transcript.md"), `${lines.join("\n")}\n`);

if (globalThis.gc) globalThis.gc();
const endRss = process.memoryUsage().rss;

function botMetrics(bot: string) {
  const rs = core.runs.filter((r) => r.bot === bot);
  const usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };
  for (const r of rs) {
    usage.input += r.usage.input;
    usage.output += r.usage.output;
    usage.cacheRead += r.usage.cacheRead;
    usage.cacheWrite += r.usage.cacheWrite;
  }
  return {
    runs: rs.length,
    turns: rs.reduce((a, r) => a + r.turns, 0),
    modelMs: rs.reduce((a, r) => a + r.modelMs, 0),
    usage,
    turnUsage: rs.flatMap((r) => r.turnUsage),
    declBytes: rs.find((r) => r.declBytes !== undefined)?.declBytes ?? null,
  };
}

const jinbeiFinalText = jinbeiRuns.at(-1)?.finalText ?? "";
const sceneLink = jinbeiFinalText.match(/https?:\/\/\S+/)?.[0] ?? null;

const metrics = {
  mode,
  model: modelSpec,
  wallMs,
  capped,
  timeToHandoffMs: firstHandoff ? firstHandoff.at - wallStart : null,
  timeToJinbeiFinalMs: jinbeiFinal ? jinbeiFinal - wallStart : null,
  firstMcpCallMs: firstMcpCall ? firstMcpCall.at - wallStart : null,
  hops: thread?.hops ?? 0,
  bots: { nami: botMetrics("nami"), jinbei: botMetrics("jinbei") },
  toolCalls: allTools.map((t) => ({ bot: core.runs.find((r) => r.tools.includes(t))?.bot ?? null, name: t.name, ms: t.ms ?? null, isError: t.isError ?? false })),
  runs: core.runs.map((r) => ({
    bot: r.bot,
    startMs: r.startMs - wallStart,
    endMs: r.endMs ? r.endMs - wallStart : null,
    modelMs: r.modelMs,
    turns: r.turns,
    usage: r.usage,
    turnUsage: r.turnUsage,
    declBytes: r.declBytes ?? null,
    declTools: r.declTools ?? null,
    error: r.error ?? null,
  })),
  peakRssMB: +(peakRss / 1048576).toFixed(1),
  endRssMB: +(endRss / 1048576).toFixed(1),
  sceneLink,
};
writeFileSync(join(runDir, "metrics.json"), `${JSON.stringify(metrics, null, 2)}\n`);
console.log(JSON.stringify(metrics, null, 2));
console.error(`run dir: ${runDir}`);
core.dispose();
process.exit(0);
