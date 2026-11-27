import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { defineTool, type ToolDefinition } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const execFileP = promisify(execFile);
const FIRECRAWL_TIMEOUT_MS = 120_000;

type ExecOut = { stdout: string; stderr: string };

async function runFirecrawl(args: string[]): Promise<ExecOut> {
  return await execFileP("firecrawl", args, {
    timeout: FIRECRAWL_TIMEOUT_MS,
    maxBuffer: 16 * 1024 * 1024,
  }) as ExecOut;
}

// Run tasks with at most `limit` in flight, in input order.
async function pooled<T, R>(limit: number, items: T[], fn: (item: T) => Promise<R>): Promise<R[]> {
  const out: R[] = new Array(items.length) as R[];
  let next = 0;
  async function worker(): Promise<void> {
    while (next < items.length) {
      const i = next++;
      out[i] = await fn(items[i] as T);
    }
  }
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, () => worker()));
  return out;
}

function oneLine(text: string, max: number): string {
  const flat = text.replace(/\s+/g, " ").trim();
  return flat.length > max ? `${flat.slice(0, max)}…` : flat;
}

export type ToolHost = {
  // message_bot: post into the thread and wake the target. Returns undefined on
  // success, or an error text.
  sendHandoff: (to: string, text: string) => string | undefined;
  botIds: () => string[];
  // save_draft: append one draft, returns its number.
  saveDraft: (draft: { to: string; channel: "email" | "linkedin"; role_url: string; text: string }) => number;
};

const RECENCY_TBS: Record<string, string> = { day: "qdr:d", week: "qdr:w", month: "qdr:m" };

function makeWebSearch(): ToolDefinition {
  return defineTool({
    name: "web_search",
    label: "web search",
    description:
      "Search the web. Runs each query and returns compact result lines: title — url — description.",
    parameters: Type.Object({
      queries: Type.Array(Type.String(), { minItems: 1, maxItems: 5 }),
      recency: Type.Optional(Type.Union([
        Type.Literal("day"),
        Type.Literal("week"),
        Type.Literal("month"),
      ])),
    }),
    execute: async (_id, params) => {
      const sections = await pooled(2, params.queries, async (q) => {
        const args = ["search", q, "--limit", "5", "--json"];
        if (params.recency) args.push("--tbs", RECENCY_TBS[params.recency] as string);
        try {
          const { stdout } = await runFirecrawl(args);
          const data = JSON.parse(stdout) as {
            data?: { web?: { title?: string; url?: string; description?: string }[] };
          };
          const web = data.data?.web ?? [];
          if (!web.length) return `## ${q}\n(no results)`;
          const lines = web.map((r) =>
            `${r.title ?? "(no title)"} — ${r.url ?? ""} — ${oneLine(r.description ?? "", 200)}`
          );
          return `## ${q}\n${lines.join("\n")}`;
        } catch (err) {
          return `## ${q}\nsearch failed: ${err instanceof Error ? err.message : String(err)}`;
        }
      });
      return { content: [{ type: "text", text: sections.join("\n\n") }], details: {} };
    },
  });
}

function makeWebRead(): ToolDefinition {
  return defineTool({
    name: "web_read",
    label: "web read",
    description: "Read web pages as markdown (main content only). Each page is cut to 6000 characters.",
    parameters: Type.Object({
      urls: Type.Array(Type.String(), { minItems: 1, maxItems: 4 }),
    }),
    execute: async (_id, params) => {
      const sections = await pooled(2, params.urls, async (url) => {
        try {
          const { stdout } = await runFirecrawl(["scrape", url, "--only-main-content"]);
          const cut = stdout.length > 6000 ? `${stdout.slice(0, 6000)}\n[cut]` : stdout;
          return `## ${url}\n${cut.trim()}`;
        } catch (err) {
          return `## ${url}\nread failed: ${err instanceof Error ? err.message : String(err)}`;
        }
      });
      return { content: [{ type: "text", text: sections.join("\n\n") }], details: {} };
    },
  });
}

function makeMessageBot(host: ToolHost): ToolDefinition {
  return defineTool({
    name: "message_bot",
    label: "message bot",
    description: "Hand off work to another bot. Returns at once; the other bot answers in this thread.",
    parameters: Type.Object({
      to: Type.String(),
      text: Type.String(),
    }),
    execute: async (_id, params) => {
      const error = host.sendHandoff(params.to, params.text);
      if (error) return { content: [{ type: "text", text: error }], details: {}, isError: true };
      return { content: [{ type: "text", text: `Sent to ${params.to}.` }], details: {} };
    },
  });
}

function makeSaveDraft(host: ToolHost): ToolDefinition {
  return defineTool({
    name: "save_draft",
    label: "save draft",
    description: "Save an outreach draft for the user to review. Never sends anything.",
    parameters: Type.Object({
      to: Type.String(),
      channel: Type.Union([Type.Literal("email"), Type.Literal("linkedin")]),
      role_url: Type.String(),
      text: Type.String(),
    }),
    execute: async (_id, params) => {
      const n = host.saveDraft({
        to: params.to,
        channel: params.channel,
        role_url: params.role_url,
        text: params.text,
      });
      return { content: [{ type: "text", text: `Saved draft ${n}.` }], details: {} };
    },
  });
}

export function createTools(toolNames: string[], host: ToolHost): ToolDefinition[] {
  const all: Record<string, () => ToolDefinition> = {
    web_search: makeWebSearch,
    web_read: makeWebRead,
    message_bot: () => makeMessageBot(host),
    save_draft: () => makeSaveDraft(host),
  };
  return toolNames.map((name) => {
    const make = all[name];
    if (!make) throw new Error(`unknown tool: ${name}`);
    return make();
  });
}
