// Maestro CLI: one thread "main", bots from a directory of bot files, streamed output.
// node core/src/cli.ts --model provider/id [--bots dir] [--mcp file] [--models models.json]
import { existsSync, mkdirSync, readdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import * as readline from "node:readline";
import { ModelRuntime, type McpServerConfig } from "@earendil-works/pi-coding-agent";
import { Core } from "./core.ts";
import { loadBot, type Bot } from "./bots.ts";

function argValue(flag: string): string | undefined {
  const i = process.argv.indexOf(flag);
  return i >= 0 ? process.argv[i + 1] : undefined;
}

const modelSpec = argValue("--model");
if (!modelSpec) {
  console.error("want --model provider/id");
  process.exit(1);
}
const [provider, ...rest] = modelSpec.split("/");
const modelId = rest.join("/");

const botsDir = argValue("--bots") ?? join(homedir(), "Maestro/.agents/agents");
if (!existsSync(botsDir)) {
  console.error(`bots dir not found: ${botsDir}`);
  process.exit(1);
}
const bots: Bot[] = [];
for (const file of readdirSync(botsDir).filter((f) => f.endsWith(".md")).sort()) {
  try {
    bots.push(loadBot(join(botsDir, file)));
  } catch {
    // Not every .md is a bot file (no frontmatter name); skip those.
  }
}
if (bots.length === 0) {
  console.error(`no bot files (*.md with frontmatter name) in ${botsDir}`);
  process.exit(1);
}

// MCP servers: JSON file, ${VAR} in header values comes from the environment.
const mcpPath = argValue("--mcp") ?? join(homedir(), "Maestro/mcp.json");
let mcpServers: Record<string, McpServerConfig> = {};
if (existsSync(mcpPath)) {
  const raw = JSON.parse(readFileSync(mcpPath, "utf8")) as { servers?: Record<string, McpServerConfig> };
  for (const [name, server] of Object.entries(raw.servers ?? {})) {
    const headers: Record<string, string> = {};
    const s = server as { headers?: Record<string, string> };
    for (const [key, value] of Object.entries(s.headers ?? {})) {
      headers[key] = value.replace(/\$\{(\w+)\}/g, (_m, varName: string) => {
        const envValue = process.env[varName];
        if (envValue === undefined) throw new Error(`mcp server "${name}": environment variable ${varName} is not set`);
        return envValue;
      });
    }
    mcpServers[name] = { ...server, headers } as McpServerConfig;
  }
}

const iso = new Date().toISOString().replace(/[:.]/g, "-");
const runDir = join(homedir(), `Workspace/local/maestro/cli/${iso}`);
mkdirSync(runDir, { recursive: true });

const modelsPath = argValue("--models") ?? join(homedir(), "Library/Application Support/Maestro/pi/agent/models.json");
const runtime = await ModelRuntime.create({ modelsPath, authPath: join(runDir, "auth.json") });
const model = runtime.getModel(provider, modelId);
if (!model) {
  console.error(`model ${modelSpec} not found in runtime`);
  process.exit(1);
}

const DIM = "\x1b[2m";
const RESET = "\x1b[0m";

let speaker: string | null = null;
let lastSpoke: string | null = null;

const core = new Core({
  runtime,
  model,
  bots,
  runDir,
  mcpServers,
  mcpExposure: "direct",
  onEvent: (e) => {
    if (e.kind === "delta") {
      if (speaker !== e.bot) {
        if (speaker !== null) process.stdout.write("\n");
        process.stdout.write(`${e.bot}> `);
        speaker = e.bot;
      }
      lastSpoke = e.bot;
      process.stdout.write(e.text);
    } else if (e.kind === "tool") {
      const ms = e.ms !== undefined ? ` ${e.ms}ms` : "";
      process.stdout.write(`\n${DIM}  · ${e.name}${ms}${e.isError ? " FAILED" : ""}${RESET}\n`);
    }
  },
});

console.log(`maestro cli — bots: ${bots.map((b) => b.id).join(", ")} — /quit to exit`);

const rl = readline.createInterface({ input: process.stdin, output: process.stdout, terminal: true });
rl.on("SIGINT", () => {
  const t = core.threads.get("main");
  for (const st of t?.bots.values() ?? []) void st.session?.abort();
  process.stdout.write("\n(aborted)\n");
  rl.prompt();
});

function fmtTokens(n: number): string {
  return n >= 1000 ? `${(n / 1000).toFixed(1)}k` : String(n);
}

async function loop(): Promise<void> {
  rl.prompt();
  for await (const line of rl) {
    const text = line.trim();
    if (text === "/quit") break;
    if (!text) {
      rl.prompt();
      continue;
    }
    const runsBefore = core.runs.length;
    const start = Date.now();
    const mentions = bots.some((b) => new RegExp(`@${b.id}\\b`, "i").test(text));
    if (mentions) {
      core.post("main", "user", text);
    } else {
      const target = lastSpoke ?? bots[0].id;
      core.post("main", "user", text, { wake: [target] });
    }
    await core.idle("main");
    if (speaker !== null) process.stdout.write("\n");
    speaker = null;
    const newRuns = core.runs.slice(runsBefore);
    for (const r of newRuns) {
      if (r.error) process.stdout.write(`  ! ${r.bot}: ${r.error}\n`);
    }
    const turns = newRuns.reduce((a, r) => a + r.turns, 0);
    const tokensRead = newRuns.reduce((a, r) => a + r.usage.input + r.usage.cacheRead + r.usage.cacheWrite, 0);
    const secs = ((Date.now() - start) / 1000).toFixed(1);
    const rss = Math.round(process.memoryUsage().rss / 1048576);
    process.stdout.write(`${DIM}  ${secs}s · ${turns} turns · ${fmtTokens(tokensRead)} tokens read · ${rss} MB${RESET}\n`);
    if ((rl as { closed?: boolean }).closed) break;
    rl.prompt();
  }
  rl.close();
  core.dispose();
  process.exit(0);
}
void loop();
