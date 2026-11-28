// Hand-off reliability measurement: does live Nami's @jinbei reply actually wake
// Jinbei? 10 sequential iterations, fresh Core each, no MCP. Run:
// node --expose-gc core/bench/handoff.ts [--model provider/id]
import { appendFileSync, cpSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { Core } from "../src/core.ts";
import { loadBot } from "../src/bots.ts";

function argValue(flag: string): string | undefined {
  const i = process.argv.indexOf(flag);
  return i >= 0 ? process.argv[i + 1] : undefined;
}
const modelSpec = argValue("--model") ?? "relay/grok-4.20-0309-reasoning";
const [provider, ...rest] = modelSpec.split("/");
const modelId = rest.join("/");

const iso = new Date().toISOString().replace(/[:.]/g, "-");
const outDir = join(homedir(), `Workspace/local/maestro/bench-2026-11-28/handoff-${iso}`);
mkdirSync(outDir, { recursive: true });
const resultsPath = join(outDir, "results.jsonl");

const modelsPath = join(homedir(), "Library/Application Support/Maestro/pi/agent/models.json");
const nami = loadBot(new URL("./learning/nami.md", import.meta.url).pathname);
const jinbeiFile = loadBot(new URL("./learning/jinbei.md", import.meta.url).pathname);
const jinbei = {
  id: "jinbei",
  description: jinbeiFile.description,
  tools: [] as string[],
  mcp: {} as Record<string, string[]>,
  instructions: "Reply with the single word: received.",
};

for (let n = 0; n < 10; n++) {
  const runDir = join(outDir, `r${n}`);
  mkdirSync(join(runDir, "agent"), { recursive: true });
  cpSync(new URL("./learning/jobs", import.meta.url).pathname, join(runDir, "jobs"), { recursive: true });
  const runtime = await ModelRuntime.create({ modelsPath, authPath: join(runDir, "auth.json") });
  const model = runtime.getModel(provider, modelId);
  if (!model) throw new Error(`model ${modelSpec} not found`);
  const core = new Core({ runtime, model, bots: [nami, jinbei], runDir });

  const postAt = Date.now();
  core.post("bench", "user", "@nami Read jobs/elip.md and jobs/plansom.md and hand Jinbei the skill gaps.");
  const CAP_MS = 120_000;
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

  const namiRuns = core.runs.filter((r) => r.bot === "nami");
  const jinbeiRuns = core.runs.filter((r) => r.bot === "jinbei" && r.prompt.includes("nami:"));
  const namiRun = namiRuns.at(-1);
  const usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };
  for (const r of namiRuns) {
    usage.input += r.usage.input;
    usage.output += r.usage.output;
    usage.cacheRead += r.usage.cacheRead;
    usage.cacheWrite += r.usage.cacheWrite;
  }
  const line = {
    n,
    jinbeiRan: jinbeiRuns.length > 0,
    namiTurns: namiRuns.reduce((a, r) => a + r.turns, 0),
    namiMs: namiRun?.endMs !== undefined && namiRun ? namiRun.endMs - namiRun.startMs : null,
    msToJinbeiStart: jinbeiRuns.length > 0 ? jinbeiRuns[0].startMs - postAt : null,
    namiTools: [...new Set(namiRuns.flatMap((r) => r.tools.map((t) => t.name)))],
    namiUsage: usage,
    namiFinal: (namiRun?.finalText ?? "").slice(0, 300),
    hops: core.threads.get("bench")?.hops ?? 0,
    capped,
    errors: core.runs.filter((r) => r.error).map((r) => r.error),
  };
  appendFileSync(resultsPath, `${JSON.stringify(line)}\n`);
  console.log(`r${n}: jinbeiRan=${line.jinbeiRan} namiTurns=${line.namiTurns} hops=${line.hops} capped=${capped}`);
  core.dispose();
}
console.log(`out dir: ${outDir}`);
process.exit(0);
