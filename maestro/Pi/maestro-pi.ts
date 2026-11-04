import { ModelRuntime, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { join } from "node:path";
import { Type } from "typebox";

export default function (pi: ExtensionAPI) {
  // Maestro delivers the message: it reads the notify below and wakes the other bot.
  pi.registerTool({
    name: "message_bot",
    label: "Message bot",
    description:
      "Send a message to another Maestro bot by name. It replies later in a new message to you; do not wait for it.",
    parameters: Type.Object({
      to: Type.String({ description: "Exact name of the bot" }),
      message: Type.String({ description: "What you need from that bot, with all needed context" }),
    }),
    async execute(_id, params) {
      return { content: [{ type: "text", text: `Sent to ${params.to}.` }], details: undefined };
    },
  });
  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName !== "message_bot") return;
    const bots = (process.env.MAESTRO_BOTS ?? "").split("\n").filter(Boolean);
    const input = event.input as { to: string };
    if (!bots.includes(input.to)) {
      return { block: true, reason: `No bot named "${input.to}". Bots: ${bots.join(", ") || "none"}.` };
    }
    ctx.ui.notify(JSON.stringify({ handoff: event.input }), "info");
  });
  const runtime = async () => {
    const directory = process.env.PI_CODING_AGENT_DIR;
    if (!directory) throw new Error("Missing pi configuration directory");
    return ModelRuntime.create({ authPath: join(directory, "auth.json"), modelsPath: join(directory, "models.json") });
  };
  pi.registerCommand("maestro-providers", {
    description: "List pi providers for Maestro",
    async handler(_, ctx) {
      const models = await runtime();
      ctx.ui.notify(JSON.stringify({ providers: models.getProviders().map(provider => ({
        id: provider.id,
        name: provider.name,
        connected: models.hasConfiguredAuth(provider.id),
        apiKey: Boolean(provider.auth.apiKey?.login),
        oauth: Boolean(provider.auth.oauth),
      })) }), "info");
    },
  });
  pi.registerCommand("maestro-connect", {
    description: "Sign in to a pi provider from Maestro",
    async handler(args, ctx) {
      const [provider, method] = args.trim().split(/\s+/);
      if (!provider || (method !== "api_key" && method !== "oauth")) throw new Error("Choose a provider and login method");
      try {
        const models = await runtime();
        await models.login(provider, method, {
          async prompt(prompt) {
            if (prompt.type === "select") {
              const choice = await ctx.ui.select(prompt.message, prompt.options.map(option => option.label));
              const value = prompt.options.find(option => option.label === choice)?.id;
              if (!value) throw new Error("Sign-in cancelled");
              return value;
            }
            const value = await ctx.ui.input(prompt.type === "secret" ? "maestro.secret" : prompt.message, prompt.message);
            if (!value?.trim()) throw new Error("Sign-in cancelled");
            return value.trim();
          },
          notify(event) { ctx.ui.notify(JSON.stringify({ authEvent: event }), "info"); },
        });
        ctx.ui.notify("Provider connected", "info");
      } catch {
        ctx.ui.notify("Sign-in cancelled or failed.", "error");
      }
    },
  });
  pi.on("tool_call", async (event, ctx) => {
    if (!event.toolName.startsWith("mcp__")) return;
    const hints = pi.getAllTools().find(tool => tool.name === event.toolName)?.annotations;
    if (hints?.readOnlyHint === true) return;
    if (!(await ctx.ui.confirm("Approve tool call", `${event.toolName}\n${JSON.stringify(event.input)}`))) {
      return { block: true, reason: "The user did not approve this change." };
    }
  });
}
