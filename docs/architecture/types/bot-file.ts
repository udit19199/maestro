// Frontmatter of the workspace files: bots (.agents/agents/<id>.md) and routines (.agents/maestro/routines/<id>.md).
// Written by people, so the loader validates every field and reports errors per field path (bot-files.md §4).

import type { EffectClass, PolicyRule, ThinkingLevel } from "./domain.ts";

/** Top-level keys mean the same thing in Claude Code, Cursor, pi-subagents and Antigravity. */
export interface BotFileFrontmatter {
  name: string; // must equal the file stem
  description: string; // max 1024 chars
  model?: "inherit"; // other tools read this; Maestro reads maestro.model
  tools?: string; // Claude-style list for other tools, e.g. "Read, Grep"; Maestro reads maestro.tools
  maestro: BotFileMaestro;
}

export interface BotFileMaestro {
  version: 1;
  display_name?: string; // default: name with a capital letter
  model?: string; // "provider/model", e.g. "relay/claude-sonnet-5-5"; default: workspace default
  thinking?: ThinkingLevel; // default "medium"
  skills?: string[]; // skill folder names under .agents/skills; default none
  mcp?: string[]; // server names from .agents/mcp.json; default none
  tools?: {
    files?: boolean; // default false
    shell?: boolean; // default false
    mail?: boolean; // default false
    calendar?: boolean; // default false
    messages?: boolean; // default false
    web?: boolean; // default false
  };
  mentions?: string[]; // extra @names; the id is always one
  policy?: Partial<Record<EffectClass, PolicyRule>>; // permissions.md §3; "destructive: auto" is an error
  work_dir?: string; // relative to the workspace; default "work/<id>"
  color?: string; // "#rrggbb"
}

export type RoutineScheduleFile =
  | { cron: string; tz: string }
  | { every_minutes: number }
  | { at: string } // ISO 8601 with offset
  | { mail: { query: string; account?: string } }; // account: an address; default any

export interface RoutineFileFrontmatter {
  name: string; // must equal the file stem
  description: string;
  maestro: {
    version: 1;
    bots: string[]; // bot ids, at least one
    lead?: string; // one of bots; default the first
    schedule: RoutineScheduleFile;
    catch_up_hours?: number; // default: workspace setting
    notify?: "none" | "imessage"; // default "none"
  };
}
