// Benchmark: Jinbei builds a learning-plan scene in Excalidraw+ over MCP from a FIXED
// handoff fixture (no live Nami), so direct/codemode/hybrid exposure can be compared
// fairly. Grades the resulting scene over read-only MCP calls. Run:
// node --expose-gc core/bench/learning.ts --mode direct|codemode|hybrid --task plan|board [--model provider/id] [--out dir]
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { Core, type RunMetrics } from "../src/core.ts";
import { loadBot } from "../src/bots.ts";

function argValue(flag: string): string | undefined {
  const i = process.argv.indexOf(flag);
  return i >= 0 ? process.argv[i + 1] : undefined;
}

const mode = argValue("--mode");
if (mode !== "direct" && mode !== "codemode" && mode !== "hybrid") throw new Error("want --mode direct|codemode|hybrid");
const task = argValue("--task");
if (task !== "plan" && task !== "board") throw new Error("want --task plan|board");
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
const outParent = argValue("--out") ?? join(homedir(), "Workspace/local/maestro/bench-2026-11-28");
const runDir = join(outParent, `learning-${mode}-${iso}`);
mkdirSync(join(runDir, "agent"), { recursive: true });

const hhmmss = new Date().toISOString().slice(11, 19).replace(/:/g, "");
const title = `Bench ${task} ${mode} ${hhmmss}`;

const modelsPath = join(homedir(), "Library/Application Support/Maestro/pi/agent/models.json");
const runtime = await ModelRuntime.create({ modelsPath, authPath: join(runDir, "auth.json") });
const model = runtime.getModel(provider, modelId);
if (!model) throw new Error(`model ${modelSpec} not found in runtime`);

const jinbei = loadBot(new URL("./learning/jinbei.md", import.meta.url).pathname);
const core = new Core({
  runtime,
  model,
  bots: [jinbei],
  runDir,
  mcpServers: {
    excalidraw: {
      type: "http",
      url: "https://api.excalidraw.com/api/v1/mcp",
      headers: { Authorization: `Bearer ${token}` },
    },
  },
  mcpExposure: mode,
});

let peakRss = process.memoryUsage().rss;
const sampler = setInterval(() => {
  peakRss = Math.max(peakRss, process.memoryUsage().rss);
}, 100);

const handoffText = readFileSync(new URL("./learning/handoff.md", import.meta.url), "utf8").trim();
const wallStart = Date.now();
core.post("bench", "nami", handoffText, { noMentions: true });
let taskText = `Jinbei: build the plan from Nami's gaps. Title the scene "${title}".`;
if (task === "board") {
  taskText +=
    ' Under the table in the same scene, add one sticky-note board per week (4 boards). Title each board "Week N: <topic>" and give it three clusters named Learn, Build and Check, with 2 to 3 notes each.';
}
core.post("bench", "user", taskText, { wake: ["jinbei"] });

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
const jinbeiRuns = core.runs.filter((r) => r.bot === "jinbei");

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
    const limit = t.isError ? 4000 : 500;
    const cut = args.length > limit ? `${args.slice(0, limit)}…` : args;
    lines.push(`- ${t.name}(${cut}) — ${t.ms ?? "?"}ms${t.isError ? " ERROR" : ""}`);
    if (t.error) lines.push(`  error: ${t.error}`);
  }
  if (r.finalText) lines.push("", "Final text:", "", r.finalText);
  if (r.error) lines.push("", `ERROR: ${r.error}`);
  lines.push("");
});
writeFileSync(join(runDir, "transcript.md"), `${lines.join("\n")}\n`);

if (globalThis.gc) globalThis.gc();
const endRss = process.memoryUsage().rss;

const jinbeiFinalText = jinbeiRuns.at(-1)?.finalText ?? "";
const sceneLink = jinbeiFinalText.match(/https?:\/\/\S+/)?.[0] ?? null;

// ---- Grader: read-only MCP calls over plain JSON-RPC/fetch. ----
type Grade = {
  link: boolean;
  title?: boolean;
  table?: boolean;
  boards?: boolean;
  layoutText?: string;
  pass: boolean;
  error?: string;
};
const grade: Grade = { link: false, pass: false };

const MCP_URL = "https://api.excalidraw.com/api/v1/mcp";
async function rpcParse(res: Response): Promise<unknown> {
  const text = await res.text();
  for (const line of text.split("\n")) {
    if (line.startsWith("data:")) return JSON.parse(line.slice(5).trim());
  }
  return JSON.parse(text);
}
if (sceneLink) {
  grade.link = true;
  const sceneId = sceneLink.split("/").at(-1) ?? "";
  const baseHeaders: Record<string, string> = {
    Authorization: `Bearer ${token}`,
    "content-type": "application/json",
    accept: "application/json, text/event-stream",
  };
  try {
    const initRes = await fetch(MCP_URL, {
      method: "POST",
      headers: baseHeaders,
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "maestro-bench", version: "0" } },
      }),
    });
    // The server is stateless in practice: no mcp-session-id header comes back and
    // tools/call works without it. Use the header when present, proceed without otherwise.
    const sessionId = initRes.headers.get("mcp-session-id");
    const headers = sessionId ? { ...baseHeaders, "mcp-session-id": sessionId } : baseHeaders;
    await fetch(MCP_URL, {
      method: "POST",
      headers,
      body: JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }),
    });
    let nextId = 2;
    const call = async (name: string, args: Record<string, unknown>): Promise<unknown> => {
      const res = await fetch(MCP_URL, {
        method: "POST",
        headers,
        body: JSON.stringify({ jsonrpc: "2.0", id: nextId++, method: "tools/call", params: { name, arguments: args } }),
      });
      const msg = (await rpcParse(res)) as { result?: { content?: { type: string; text?: string }[] }; error?: { message?: string } };
      if (msg.error) throw new Error(msg.error.message ?? "rpc error");
      return msg.result;
    };
    const textOf = (result: unknown): string => {
      const r = result as { content?: { type: string; text?: string }[] };
      return r?.content?.find((c) => c.type === "text")?.text ?? "";
    };

    // title check
    const sceneRes = textOf(await call("get_scene", { sceneId }));
    let sceneName: string | undefined;
    try {
      const scene = JSON.parse(sceneRes) as Record<string, unknown>;
      const data = (scene.data ?? scene) as Record<string, unknown>;
      const meta = (data.metadata ?? {}) as Record<string, unknown>;
      sceneName = (data.name ?? data.title ?? meta.name ?? meta.title) as string | undefined;
    } catch {
      throw new Error(`get_scene result is not JSON: ${sceneRes.slice(0, 200)}`);
    }
    if (sceneName === undefined) throw new Error("get_scene result has no obvious name/title field");
    grade.title = sceneName === title;

    // table + boards check
    const contentRes = textOf(await call("get_scene_content", { sceneId }));
    const content = JSON.parse(contentRes) as { elements?: { type?: string; isDeleted?: boolean; originalText?: string; text?: string }[] };
    const texts = (content.elements ?? [])
      .filter((el) => el.type === "text" && !el.isDeleted)
      .map((el) => (el.originalText ?? el.text ?? "").trim());
    writeFileSync(join(runDir, "scene-texts.json"), `${JSON.stringify(texts, null, 2)}\n`);
    const lower = texts.map((t) => t.toLowerCase());
    const hasExact = (want: string) => lower.includes(want.toLowerCase());
    const colsOk = ["Week", "Topic", "Small build", "Job posting"].every(hasExact);
    const postingsOk = texts.filter((t) => t === "Plansom" || t === "Elip" || t === "Both").length >= 4;
    const weeksOk = [1, 2, 3, 4].every((n) => texts.some((t) => new RegExp(`^(week\\s*)?${n}$`, "i").test(t)));
    grade.table = colsOk && postingsOk && weeksOk;
    if (task === "board") {
      const titlesOk = [1, 2, 3, 4].every((n) => texts.some((t) => new RegExp(`^Week\\s*${n}\\s*:`, "i").test(t)));
      const clustersOk = ["Learn", "Build", "Check"].every((c) => lower.filter((t) => t === c.toLowerCase()).length >= 4);
      grade.boards = titlesOk && clustersOk;
    }

    // layout text
    const layoutRes = textOf(await call("check_scene_layout", { sceneId }));
    grade.layoutText = layoutRes.slice(0, 600);
  } catch (err) {
    grade.error = err instanceof Error ? err.message : String(err);
  }
}
grade.pass = grade.link && grade.title === true && grade.table === true && (task === "plan" || grade.boards === true);

function jinbeiMetrics() {
  const rs = jinbeiRuns;
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
    declTools: rs.find((r) => r.declTools !== undefined)?.declTools ?? null,
  };
}

const metrics = {
  mode,
  task,
  model: modelSpec,
  title,
  wallMs,
  capped,
  jinbei: jinbeiMetrics(),
  toolCalls: allTools.map((t) => ({ bot: core.runs.find((r) => r.tools.includes(t))?.bot ?? null, name: t.name, ms: t.ms ?? null, isError: t.isError ?? false, error: t.error ?? null })),
  errors: core.runs.filter((r) => r.error).map((r) => ({ bot: r.bot, error: r.error })),
  peakRssMB: +(peakRss / 1048576).toFixed(1),
  endRssMB: +(endRss / 1048576).toFixed(1),
  sceneLink,
  grade,
};
writeFileSync(join(runDir, "metrics.json"), `${JSON.stringify(metrics, null, 2)}\n`);
console.log(JSON.stringify(metrics, null, 2));
console.error(`run dir: ${runDir}`);
core.dispose();
process.exit(0);
