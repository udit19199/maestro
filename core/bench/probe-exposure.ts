// Offline probe: what does Jinbei's session actually declare to the model in each
// exposure mode? Uses the faux provider (no model calls) against the real Excalidraw
// MCP server. Declarations are read from the context the faux model receives, which
// is post-projection: exactly what a real provider would be sent. The only server
// calls are one read-only list_collections per non-direct mode; the hidden-tool check
// is a `typeof` inside the script VM, which cannot reach the server.
// Run: node core/bench/probe-exposure.ts
import { mkdtempSync, readFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { fauxAssistantMessage, fauxProvider, fauxText, fauxToolCall } from "@earendil-works/pi-ai";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { Core } from "../src/core.ts";
import { loadBot } from "../src/bots.ts";

const ALLOWED = [
  "list_collections", "list_collection_scenes", "create_collection_scene", "create_scene",
  "get_scene", "get_scene_content", "edit_scene_content", "read_diagram_format",
  "create_diagram", "create_mermaid_diagram", "create_table", "create_sticky_notes",
  "check_scene_layout", "take_screenshot",
];

// Token in memory only; never printed or written.
const creds = JSON.parse(readFileSync(join(homedir(), ".config/excalidraw-cli/credentials.json"), "utf8")) as {
  origins: Record<string, { accessToken: string }>;
};
const token = creds.origins["https://api.excalidraw.com"]?.accessToken;
if (!token) throw new Error("no excalidraw token");

const jinbei = loadBot(new URL("./learning/jinbei.md", import.meta.url).pathname);

type DeclTool = { name: string; description?: string; parameters?: unknown };
type CtxMessage = {
  role: string;
  toolName?: string;
  content?: unknown;
  toolsAdded?: DeclTool[];
};

function textOf(content: unknown): string {
  if (Array.isArray(content)) return content.map((c) => (typeof c?.text === "string" ? c.text : "")).join("");
  return typeof content === "string" ? content : "";
}

for (const mode of ["direct", "codemode", "hybrid"] as const) {
  const dir = mkdtempSync(join(tmpdir(), `maestro-probe-${mode}-`));
  const faux = fauxProvider({ provider: "faux", models: [{ id: "m", contextWindow: 10_000_000 }], tokensPerSecond: 1e9 });
  const runtime = await ModelRuntime.create({ modelsPath: null, authPath: join(dir, "auth.json"), allowModelNetwork: false });
  runtime.registerNativeProvider(faux.provider);
  await runtime.setRuntimeApiKey("faux", "k");
  const model = runtime.getModel("faux", "m");
  if (!model) throw new Error("faux model missing");

  const captured: { declTools?: DeclTool[]; toolResults: string[] } = { toolResults: [] };
  function step(ctx: { messages: CtxMessage[] }) {
    if (!captured.declTools) {
      const first = ctx.messages.find((m) => m.role === "system" && m.toolsAdded?.length);
      captured.declTools = first?.toolsAdded ?? [];
    }
    const last = ctx.messages.at(-1);
    if (last?.role === "toolResult") captured.toolResults.push(textOf(last.content));
    const nResults = ctx.messages.filter((m) => m.role === "toolResult").length;
    if (mode === "direct") return fauxAssistantMessage(fauxText("done"));
    if (nResults === 0) {
      return fauxAssistantMessage(
        [fauxToolCall("codemode", { code: "return await tools.mcp__excalidraw__list_collections({})" })],
        { stopReason: "toolUse" },
      );
    }
    if (nResults === 1) {
      return fauxAssistantMessage(
        [fauxToolCall("codemode", { code: "return typeof tools.mcp__excalidraw__delete_scene" })],
        { stopReason: "toolUse" },
      );
    }
    return fauxAssistantMessage(fauxText("done"));
  }
  faux.appendResponses(Array.from({ length: 20 }, () => step));

  const core = new Core({
    runtime,
    model,
    bots: [jinbei],
    runDir: dir,
    mcpServers: {
      excalidraw: {
        type: "http",
        url: "https://api.excalidraw.com/api/v1/mcp",
        headers: { Authorization: `Bearer ${token}` },
      },
    },
    mcpExposure: mode,
    mcpAllow: { excalidraw: ALLOWED },
  });
  core.post("t1", "user", "@jinbei probe");
  await core.idle("t1");

  const decl = captured.declTools ?? [];
  let bytes = 0;
  for (const tool of decl) {
    bytes += Buffer.byteLength(JSON.stringify({ name: tool.name, description: tool.description, parameters: tool.parameters }));
  }
  const codemodeDesc = decl.find((t) => t.name === "codemode")?.description ?? "";
  console.log(`\n== mode ${mode}`);
  console.log("declared tools:", decl.map((t) => t.name).join(", ") || "(none)");
  console.log("declaration bytes:", bytes);
  console.log("core declBytes (payload capture or fallback):", core.runs[0]?.declBytes);
  if (mode !== "direct") {
    console.log("codemode description contains mcp__excalidraw__create_table:", codemodeDesc.includes("mcp__excalidraw__create_table"));
    console.log("codemode description contains `columns`:", codemodeDesc.includes("columns"));
    console.log("list_collections result (first 300 chars):", (captured.toolResults[0] ?? "(none)").slice(0, 300));
    console.log("typeof delete_scene result:", (captured.toolResults[1] ?? "(not captured)").slice(0, 200));
  }
  core.dispose();
}
process.exit(0);
