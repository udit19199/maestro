// Fair-comparison suite: plan/board x direct/codemode/hybrid, rotated per round,
// one child bench process at a time. Run:
// node core/bench/learning-suite.ts [--rounds N] [--model provider/id]
import { appendFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { execFileSync, spawn } from "node:child_process";

function argValue(flag: string): string | undefined {
  const i = process.argv.indexOf(flag);
  return i >= 0 ? process.argv[i + 1] : undefined;
}
const rounds = Number(argValue("--rounds") ?? "5");
const model = argValue("--model") ?? "relay/grok-4.20-0309-reasoning";

const iso = new Date().toISOString().replace(/[:.]/g, "-");
const suiteDir = join(homedir(), `Workspace/local/maestro/bench-2026-11-28/fair-${iso}`);
mkdirSync(suiteDir, { recursive: true });

writeFileSync(
  join(suiteDir, "SPEC.md"),
  `> Dude, setup a fair test man.
model: relay/grok-4.20-0309-reasoning
tasks: plan, board
modes: direct, codemode, hybrid
rounds: 5
runs: 30
input: fixed handoff fixture core/bench/learning/handoff.md
`,
);

const resultsPath = join(suiteDir, "results.jsonl");
const statusPath = join(suiteDir, "STATUS.md");
function writeStatus(stage: string, progress: string, lastError: string) {
  writeFileSync(
    statusPath,
    `stage: ${stage}\nprogress: ${progress}\nlast error: ${lastError}\nupdated: ${new Date().toISOString()}\n`,
  );
}
function countResults(): number {
  try {
    return readFileSync(resultsPath, "utf8").trim().split("\n").filter(Boolean).length;
  } catch {
    return 0;
  }
}

const MODES = ["direct", "codemode", "hybrid"];
const TASKS = ["plan", "board"];
const total = rounds * 6;
writeStatus("running", `0/${total}`, "none");

const repoRoot = new URL("../..", import.meta.url).pathname;
const benchPath = join(repoRoot, "core/bench/learning.ts");

let lastError = "none";
let consecutiveModelFailures = 0;
let failed = false;

for (let r = 0; r < rounds && !failed; r++) {
  const modes = MODES.map((_, i) => MODES[(i + r) % MODES.length]);
  for (const task of TASKS) {
    for (const mode of modes) {
      // Refresh the OAuth token; it expires hourly.
      try {
        execFileSync("excalidraw", ["whoami"], { stdio: "ignore" });
      } catch {
        // whoami failure is not fatal; the child will error if the token is bad.
      }
      const code = await new Promise<number>((resolve) => {
        const child = spawn(
          "node",
          ["--expose-gc", benchPath, "--mode", mode, "--task", task, "--model", model, "--out", suiteDir],
          { cwd: repoRoot, stdio: ["ignore", "pipe", "pipe"] },
        );
        let out = "";
        child.stdout.on("data", (d) => (out += d));
        child.stderr.on("data", (d) => (out += d));
        child.on("error", () => resolve(1));
        child.on("close", (c) => resolve(c ?? 1));
      });
      // metrics.json is the last JSON object the child printed; read it from the newest run dir instead.
      let metricsLine: string | null = null;
      try {
        const { readdirSync } = await import("node:fs");
        const dirs = readdirSync(suiteDir)
          .filter((d) => d.startsWith(`learning-${mode}-`))
          .sort();
        const latest = dirs.at(-1);
        if (latest) {
          const metrics = JSON.parse(readFileSync(join(suiteDir, latest, "metrics.json"), "utf8")) as Record<string, unknown>;
          metrics.round = r;
          metrics.runDir = join(suiteDir, latest);
          metricsLine = JSON.stringify(metrics);
          const errs = (metrics.errors ?? []) as { error?: string }[];
          const runError = errs.map((e) => e.error ?? "").join("; ");
          if (errs.length > 0) lastError = `round ${r} ${task}/${mode}: ${runError.slice(0, 200)}`;
          if (errs.length > 0 && /model|provider|429/i.test(runError)) {
            consecutiveModelFailures++;
          } else {
            consecutiveModelFailures = 0;
          }
        }
      } catch (err) {
        consecutiveModelFailures++;
        lastError = `round ${r} ${task}/${mode}: ${err instanceof Error ? err.message : String(err)}`;
      }
      if (metricsLine) appendFileSync(resultsPath, `${metricsLine}\n`);
      writeStatus("running", `${countResults()}/${total}`, lastError);
      if (consecutiveModelFailures >= 2) {
        writeStatus("failed", `${countResults()}/${total}`, lastError);
        failed = true;
        break;
      }
    }
    if (failed) break;
  }
}

if (!failed) {
  writeStatus(countResults() === total ? "done" : "failed", `${countResults()}/${total}`, lastError);
  if (countResults() !== total) process.exit(1);
}
console.log(`suite dir: ${suiteDir}`);
process.exit(failed ? 1 : 0);
