# Product

## Register

product

## Users

Primary user: a macOS power user who wants a personal AI assistant for daily life tasks, not a coding IDE.

Context of use:
- Morning briefing and quick follow-ups from the menu bar or main window
- Longer research and planning sessions in dedicated agent threads
- Remote commands via iMessage while away from the desk
- Occasional file or shell work when a folder is attached, not as the default mode

Job to be done: open Zoro, see what matters today, ask anything, and pick up prior context without managing projects or workspaces.

## Product Purpose

Zoro is a native macOS personal AI assistant built with SwiftUI and FoundationModels. It surfaces a daily briefing, routes work to specialized agents, searches the web, manages calendar events and reminders, reads and writes Apple Notes, sends iMessage replies, and optionally operates on files in an attached folder.

Success looks like replacing Hermes as the daily driver after a feature checklist pass and a 14-day daily driver trial: persistent conversations, reliable iMessage remote control, background briefing refresh while the menu bar app runs, and fast access from the menu bar.

Zoro is briefing-first, not chat-first. The home screen is a dashboard (yesterday recap, today suggestions) with a slim composer at the bottom. Chat threads live in the sidebar; folders are optional attachments for file and terminal tools.

## Brand Personality

Voice: direct, calm, and capable. Zoro should feel like a competent helper, not a hype product demo.

Three words: native, focused, trustworthy.

Emotional goal: reduce friction. The user should open Zoro and immediately see what matters today, then ask a follow-up without setup ceremony.

## Anti-references

- Cursor, VS Code, or any dark IDE aesthetic as the main UI metaphor
- Coding-agent positioning: "write code", "run tests", "inspect repo" as default copy or primary flows
- Generic AI chat slop: purple gradients everywhere, sparkle icons as brand, glassmorphism overlays, neon accents
- Project dashboards, kanban boards, or workspace gates that block chatting
- Web-app patterns pasted onto macOS: floating cards with heavy drop shadows, rounded-everything SaaS chrome
- Hermes-style external CLI orchestration as the mental model (Zoro is in-app and native)
- Chat-first landing pages with empty-state prompts as the primary home experience

## Design Principles

1. **Briefing before conversation** — Home shows yesterday recap and today suggestions. The composer is always available but secondary to orientation.
2. **macOS-native first** — Use system scenes, semantic colors, SF typography, and platform conventions (Settings scene, MenuBarExtra, NavigationSplitView). Menu bar is primary; Dock icon hidden by default with a Settings toggle. Login item on by default.
3. **Persistent memory** — History survives restarts. Hybrid memory: editable profile file plus conservative auto-extraction. Desktop and iMessage channels stay separate and identifiable.
4. **One agent per thread** — Pick an agent at chat creation, or let Default suggest a handoff. No mid-chat agent switching in v1.
5. **Replace Hermes, don't mimic it** — Match daily workflows (text me an answer, research and save, remind me) with native tools and in-app UX, not terminal glue.

## Non-goals

- Not a coding agent or IDE replacement
- Not a team workspace or multi-user product
- Not a browser-based chat wrapper
- Not dependent on external CLIs for core features (iMessage, Notes, calendar)
- Not requiring a workspace folder to start a conversation
- Not a generic chat app where the empty composer is the only home screen

## Agents

Four agents, one per thread:

| Agent | Role | Default model |
| --- | --- | --- |
| **Default** | Router for general tasks, Apple Notes, and handoff suggestions | Apple Intelligence |
| **Research** | Web and deep research (blocker workflows) | ChatGPT when OpenAI key exists; Apple Intelligence until then |
| **Planner** | Calendar, week/day planning, memory writes for progress | ChatGPT when OpenAI key exists; Apple Intelligence until then |
| **Teach** | Personal tutoring with curriculum state in dedicated threads (Matt Pocock teach methodology as foundation) | ChatGPT when OpenAI key exists; Apple Intelligence until then |

Agent selection: user picks at chat creation, or Default suggests a handoff to a new thread. No mid-chat switching in v1.

## Memory

Hybrid system:
- Editable profile file the user can review and edit directly
- Conservative auto-extraction from conversations
- Silent save with a "memory updated" notice in chat
- Settings Memory panel for review and undo
- Planner and Teach agents may write progress silently

## Models

- **Default agent** → user-selected backend (Apple Intelligence by default)
- **Research, Planner, Teach** → OpenAI when an OpenAI API key is configured; Apple Intelligence as fallback
- **Available backends:** Apple Intelligence (on-device), Private Cloud Compute, OpenAI (`OpenAILanguageModel.swift`), Codex/ChatGPT subscription (`CodexLanguageModel.swift`), Claude (`ClaudeForFoundationModels` SPM), Gemini (`GeminiLanguageModel.swift`)

## Core Flows

1. **Morning briefing** — Open app or menu bar; see yesterday recap and today suggestions sourced from calendar, reminders, profile, and recent Zoro chats. Background refresh while Zoro runs (menu bar keeps the process alive).
2. **Ask and resume** — Type in the slim composer or open a thread from the sidebar; receive a streamed reply; quit and relaunch with history intact.
3. **Search and research** — Route to Research agent. Web search via Tavily; deep research shows progress in an activity panel and can save results to Notes.
4. **Life admin** — Route to Planner agent. Propose calendar events in chat; user confirms; events added to Apple Calendar. Reminders and memory updates follow the same confirm pattern where applicable.
5. **Apple Notes** — Default agent handles read and write via natural language.
6. **Personal tutoring** — Route to Teach agent. Dedicated threads carry curriculum state across sessions.
7. **Remote via iMessage (day-one blocker)** — Whitelisted sender texts a command; each inbound text starts a **new** conversation (thread continuation deferred to Phase 2). Default agent unless prefixed: `research:`, `plan:`, or `teach:`.
8. **Optional file work** — User attaches a folder in the composer; file read/write, patch, and terminal tools scope to that folder. Shell requires confirmation for every command in v1.
9. **Menu bar access** — Icon in the menu bar for briefing, new chat, open window, recent threads, and settings.

## Briefing sources

**v1:** Calendar, reminders, user profile, recent Zoro chats.

**Phase 2:** Email via Gmail integration (backend code exists; agent registration and Settings UI wiring pending).

## Deferred (Phase 2+)

- ⌘K command palette (was day-one; now Phase 2)
- Email in briefing
- iMessage thread continuation (same conversation across texts)
- Shell allowlist and auto-run without per-command confirmation

## Accessibility & Inclusion

- Follow macOS Human Interface Guidelines and Dynamic Type where SwiftUI allows scaling
- Respect system Reduce Motion; avoid decorative animation when reduced motion is enabled
- Maintain sufficient contrast using semantic system colors in both light and dark mode
- Support keyboard navigation for sidebar, composer, briefing sections, and settings
- Error and permission states (Full Disk Access, missing API keys) must be plain language with a clear next step
