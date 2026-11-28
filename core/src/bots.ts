import { readFileSync } from "node:fs";
import { parseFrontmatter } from "@earendil-works/pi-coding-agent";

export type Bot = {
  id: string;
  description: string;
  tools: string[];
  // MCP server name -> the tool names of that server the bot may use; every
  // other tool of the server stays hidden.
  mcp: Record<string, string[]>;
  instructions: string;
};

export function loadBot(path: string): Bot {
  const { frontmatter, body } = parseFrontmatter<{
    name?: string;
    description?: string;
    maestro?: { tools?: string[]; mcp?: Record<string, string[]> };
  }>(readFileSync(path, "utf8"));
  if (!frontmatter.name) throw new Error(`bot file ${path}: frontmatter missing name`);
  return {
    id: frontmatter.name,
    description: frontmatter.description ?? "",
    tools: frontmatter.maestro?.tools ?? [],
    mcp: frontmatter.maestro?.mcp ?? {},
    instructions: body.trim(),
  };
}
