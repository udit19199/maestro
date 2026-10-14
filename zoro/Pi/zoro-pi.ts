import { ModelRuntime, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { join } from "node:path";

export default function (pi: ExtensionAPI) {
  const runtime = async () => {
    const directory = process.env.PI_CODING_AGENT_DIR;
    if (!directory) throw new Error("Missing pi configuration directory");
    return ModelRuntime.create({ authPath: join(directory, "auth.json"), modelsPath: join(directory, "models.json") });
  };
  pi.registerCommand("zoro-providers", {
    description: "List pi providers for Zoro",
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
  pi.registerCommand("zoro-connect", {
    description: "Sign in to a pi provider from Zoro",
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
            const value = await ctx.ui.input(prompt.type === "secret" ? "zoro.secret" : prompt.message, prompt.message);
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
