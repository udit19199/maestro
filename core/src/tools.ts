import { defineTool, type ToolDefinition } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

export type ToolHost = {
  // message_bot: post into the thread and wake the target. Returns undefined on
  // success, or an error text.
  sendHandoff: (to: string, text: string) => string | undefined;
  botIds: () => string[];
  // save_draft: append one draft, returns its number.
  saveDraft: (draft: { to: string; channel: "email" | "linkedin"; role_url: string; text: string }) => number;
};

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
    message_bot: () => makeMessageBot(host),
    save_draft: () => makeSaveDraft(host),
  };
  return toolNames
    .filter((name) => name in all)
    .map((name) => {
      const make = all[name];
      if (!make) throw new Error(`unknown tool: ${name}`);
      return make();
    });
}
