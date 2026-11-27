import { readFileSync } from "node:fs";
import { parseFrontmatter } from "@earendil-works/pi-coding-agent";

export type Bot = {
  id: string;
  description: string;
  tools: string[];
  instructions: string;
};

export function loadBot(path: string): Bot {
  const { frontmatter, body } = parseFrontmatter<{
    name?: string;
    description?: string;
    maestro?: { tools?: string[] };
  }>(readFileSync(path, "utf8"));
  if (!frontmatter.name) throw new Error(`bot file ${path}: frontmatter missing name`);
  return {
    id: frontmatter.name,
    description: frontmatter.description ?? "",
    tools: frontmatter.maestro?.tools ?? [],
    instructions: body.trim(),
  };
}
