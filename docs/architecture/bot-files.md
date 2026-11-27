# Workspace files

## 1. Layout

```
~/Maestro/                                  the workspace (Settings can move it)
  AGENTS.md                                 rules every bot reads
  .agents/
    agents/<bot>.md                         one bot per file
    skills/<skill>/SKILL.md                 Agent Skills standard
    mcp.json                                MCP servers (mcpServers format + maestro.effects)
    maestro/routines/<routine>.md           one routine per file (routines.md)
  .claude/agents  -> ../.agents/agents      links Maestro creates and repairs,
  .claude/skills  -> ../.agents/skills      so Claude Code and Cursor read the same files
  work/<bot>/                               each bot's working folder for file tools
```

There is no standard for agent files across tools (research of 27 Nov 2026: Claude Code, Cursor, OpenCode, Codex, Copilot and Antigravity all differ). They agree on Markdown with YAML frontmatter, `name`, `description`, and the body as the system prompt. Maestro uses exactly that shared part at the top level and puts everything of its own under one `maestro:` key.

## 2. A bot file

```markdown
---
name: mail
description: Handles Udit's Gmail. Use for inbox sweeps, replies and follow-ups.
model: inherit
maestro:
  version: 1
  display_name: Mail
  model: relay/claude-sonnet-5-5
  thinking: medium
  skills: [mail-triage]
  tools: { mail: true }
  mentions: [inbox]
  color: "#4f7cff"
---

You are Mail. You keep Udit's inbox at zero without him reading it.

- Archive newsletters and receipts. Draft replies for anything that needs one.
- Flag only what Udit alone can do, with the deadline.
```

Fields and defaults: [types/bot-file.ts](types/bot-file.ts) `BotFileFrontmatter`.

## 3. Rules

1. `name` equals the file stem and is the bot's id. Renaming a file in Finder makes a new bot; the app's Rename moves history to the new id in one transaction.
2. `maestro.version` is 1. A higher version marks the file `invalid` with "Made by a newer Maestro".
3. Secrets and absolute paths never go in these files. `work_dir` is relative to the workspace.
4. The body is the bot's instructions, at most 8 KB. Longer bodies are an error, so the identity block stays small (context.md §2).
5. Skills are referenced by name, never pasted in. pi lists their names and descriptions; the bot reads a skill when it needs it.
6. `policy` can loosen `own` and `outward` or tighten anything. `destructive: auto` is an error.

## 4. Loading

- The loader reads every file at start and watches the folder (FSEvents through Node `fs.watch`, debounced 300 ms).
- Each file is parsed and checked against the TypeBox schema. Errors are per field path ("maestro.tools.mail: expected true or false"). An invalid file marks that bot `invalid`: its threads show the error and it takes no runs. Other bots are not affected.
- A changed bot file applies to new sessions. Live sessions of that bot are disposed when idle, so the next run picks up the change. The shell shows "Mail was updated; open chats use it from the next message."
- A deleted file marks the bot `removed`. Its threads stay, read-only, until the file comes back.

## 5. Other tools

| Tool | Reads bots | Reads skills |
|---|---|---|
| Claude Code | via `.claude/agents` link; ignores the `maestro:` key | via `.claude/skills` link |
| Cursor | via `.claude/agents` link | `.agents/skills` directly |
| Codex, OpenCode, pi | not as bots | `.agents/skills` directly |

Export (Settings > Bots > Export) writes a folder with the bot file, its skills and its routines, with no memory, threads or connections.
</content>
