---
name: Zoro
description: A calm, native macOS briefing surface for a personal AI assistant
colors:
  window-bg: "#FFFFFF"
  window-bg-dark: "#1E1E1E"
  sidebar-bg: "#F5F5F7"
  sidebar-bg-dark: "#2A2A2A"
  chat-bg: "#FFFFFF"
  chat-bg-dark: "#1C1C1E"
  control-bg: "#EBEBEB"
  control-bg-dark: "#3A3A3C"
  text-primary: "#000000"
  text-primary-dark: "#FFFFFF"
  text-secondary: "#6E6E73"
  text-secondary-dark: "#98989D"
  accent: "#007AFF"
  accent-subtle: "#5856D6"
  user-bubble: "#007AFF"
  status-success: "#34C759"
  status-warning: "#FF9500"
  status-error: "#FF3B30"
  border-subtle: "#00000033"
  border-subtle-dark: "#FFFFFF33"
typography:
  display:
    fontFamily: "SF Pro Display, -apple-system, system-ui"
    fontSize: "28pt"
    fontWeight: 600
    lineHeight: 1.2
    letterSpacing: "normal"
  headline:
    fontFamily: "SF Pro Text, -apple-system, system-ui"
    fontSize: "17pt"
    fontWeight: 600
    lineHeight: 1.3
    letterSpacing: "normal"
  title:
    fontFamily: "SF Pro Text, -apple-system, system-ui"
    fontSize: "15pt"
    fontWeight: 600
    lineHeight: 1.35
    letterSpacing: "normal"
  body:
    fontFamily: "SF Pro Text, -apple-system, system-ui"
    fontSize: "13pt"
    fontWeight: 400
    lineHeight: 1.5
    letterSpacing: "normal"
  label:
    fontFamily: "SF Pro Text, -apple-system, system-ui"
    fontSize: "11pt"
    fontWeight: 500
    lineHeight: 1.3
    letterSpacing: "0.02em"
  code:
    fontFamily: "SF Mono, ui-monospace, Menlo, monospace"
    fontSize: "12pt"
    fontWeight: 400
    lineHeight: 1.45
    letterSpacing: "normal"
rounded:
  message: "12pt"
  composer: "16pt"
  chip: "8pt"
  avatar: "50%"
spacing:
  xs: "4pt"
  sm: "8pt"
  md: "12pt"
  lg: "16pt"
  xl: "24pt"
  sidebar-width: "240pt"
  content-max-width: "720pt"
components:
  button-primary:
    backgroundColor: "{colors.accent}"
    textColor: "#FFFFFF"
    rounded: "{rounded.chip}"
    padding: "8pt 16pt"
  button-secondary:
    backgroundColor: "{colors.control-bg}"
    textColor: "{colors.text-primary}"
    rounded: "{rounded.chip}"
    padding: "8pt 16pt"
  user-message:
    backgroundColor: "{colors.user-bubble}"
    textColor: "#FFFFFF"
    rounded: "{rounded.message}"
    padding: "10pt 16pt"
  assistant-message:
    backgroundColor: "{colors.control-bg}"
    textColor: "{colors.text-primary}"
    rounded: "{rounded.message}"
    padding: "10pt 14pt"
  composer-field:
    backgroundColor: "{colors.control-bg}"
    textColor: "{colors.text-primary}"
    rounded: "{rounded.composer}"
    padding: "12pt 16pt"
  agent-chip:
    backgroundColor: "{colors.control-bg}"
    textColor: "{colors.text-secondary}"
    rounded: "{rounded.chip}"
    padding: "6pt 12pt"
  agent-chip-selected:
    backgroundColor: "{colors.accent}"
    textColor: "#FFFFFF"
    rounded: "{rounded.chip}"
    padding: "6pt 12pt"
---

# Design System: Zoro

<!-- SEED: Target visual system for the UI/UX overhaul. Re-run document in scan mode after Phase 1 ships. -->

## Overview

**Creative North Star: "The Morning Desk"**

A native macOS window that orients the user before they ask anything: yesterday recap, today suggestions, and a slim composer when they are ready. Zoro should feel like Calendar or Reminders upgraded with an assistant, not like a developer tool or a marketing landing page.

Layout is briefing-first: sidebar for history, centered column for the home dashboard or an open thread, composer anchored at the bottom. Settings live in the native Settings scene, not inline panels that push content off screen.

**Scene sentence (light/dark):** In light mode, soft daylight on a white desk with graphite text. In dark mode, a dim evening room with warm-neutral grays and a single blue accent for actions. Both modes stay restrained; neither uses purple gradients or glow effects.

**Key Characteristics:**
- NavigationSplitView shell with 240pt sidebar and 720pt max content column
- SF Pro for all UI and message prose; SF Mono for code only
- Semantic NSColor roles, not custom hex palettes per screen
- Flat surfaces with dividers and tonal layering, not drop shadows
- Menu bar primary; Dock hidden by default (Settings toggle)
- Assistant messages read like prose; user messages use solid accent fill

## Colors

Palette follows macOS semantic colors. Hex values in frontmatter are reference anchors; implementation uses `NSColor` and SwiftUI semantic equivalents (`Color.primary`, `Color.secondary`, `NSColor.windowBackgroundColor`, `NSColor.controlBackgroundColor`, `NSColor.textBackgroundColor`).

### Primary
- **System Accent Blue** (#007AFF): Send button, selected agent chips, links, focus rings, confirm actions. One accent family per screen.

### Secondary
- **Subtle Violet** (#5856D6): Zoro avatar badge and brand mark only. Not a gradient fill for bubbles or backgrounds.

### Neutral
- **Window Background**: Main chrome and composer footer (`windowBackgroundColor`).
- **Sidebar Background** (`controlBackgroundColor`): Conversation list, grouped by Today / Yesterday / Previous 7 days.
- **Content Background** (`textBackgroundColor`): Briefing scroll area and message thread.
- **Control Surface** (`controlBackgroundColor`): Assistant bubbles, briefing cards, activity panel, composer field background.
- **Primary Text** (`labelColor` / `.primary`): Headings, briefing body, message body.
- **Secondary Text** (`.secondary`): Timestamps, metadata, section labels, empty-state hints.
- **Subtle Border** (secondary at 20% opacity): Assistant bubble stroke, briefing card edges, panel dividers.

### Named Rules
**The One Accent Rule.** Blue accent appears on primary actions and one selected state at a time. No multi-color gradients on message bubbles or briefing cards.

**The Semantic Rule.** Prefer `Color(NSColor.*)` and SwiftUI semantic colors over hardcoded RGB. Light and dark mode must come from the system, not a custom theme toggle.

## Typography

**Display Font:** SF Pro Display (system)
**Body Font:** SF Pro Text (system)
**Code Font:** SF Mono (system, monospaced design)

**Character:** Native macOS readability. Assistant replies and briefing prose use proportional body text. Monospace is reserved for inline code, API keys, and terminal output.

### Hierarchy
- **Display** (semibold, 28pt, 1.2): Home greeting ("Good morning") or date line on briefing dashboard.
- **Headline** (semibold, 17pt, 1.3): Briefing section headers (Yesterday, Today, Suggestions) and sidebar section headers.
- **Title** (semibold, 15pt, 1.35): Conversation titles in sidebar, briefing card titles, settings section labels.
- **Body** (regular, 13pt, 1.5): Briefing content, message content, composer text. Max readable width 720pt (~65-75 characters per line).
- **Label** (medium, 11pt, slight tracking): Agent chips, status pills, source badges, caption metadata.
- **Code** (regular, 12pt SF Mono): Fenced blocks and inline `code` in assistant messages only.

### Named Rules
**The Prose Rule.** Assistant messages and briefing text never use monospaced body font. Code blocks are the only monospaced regions in the thread.

## Elevation

Flat-by-default macOS surfaces. Depth comes from background tonal steps (window vs control vs text background) and 1pt dividers, not card shadows.

Hover and selection use subtle fill shifts (`accentColor.opacity(0.1)`) and system focus rings. Phase 2 command palette overlay uses a semi-transparent scrim behind a single elevated panel (`controlBackgroundColor` with corner radius 12pt).

No glassmorphism, no neon glow, no stacked shadow cards.

## Components

### Buttons
- **Shape:** System bordered / borderedProminent styles; 8pt corner radius on custom fills.
- **Primary:** Bordered prominent, system accent tint. Send, confirm calendar events, confirm shell commands.
- **Secondary:** Bordered or plain. Cancel, attach folder, sidebar actions, dismiss memory notice.
- **Hover / Focus:** System default. No custom scale or bounce animations.

### Chips (agent picker)
- **Style:** 8pt radius capsules on `controlBackgroundColor`; selected state uses accent fill with white label.
- **Agents:** Default, Research, Planner, Teach. Selected at chat creation only; no mid-thread switch in v1.
- **State:** Unselected = secondary text; selected = accent background.

### Briefing cards
- **Style:** Full-width rows or grouped sections on `textBackgroundColor`; 12pt internal padding; 1pt subtle border or divider between items.
- **Sections:** Yesterday recap, Today (calendar + reminders), Suggestions (from profile + recent chats).
- **Refresh:** Subtle "Updated" timestamp or pull-to-refresh on manual open; background refresh while menu bar app runs.
- **Actions:** Tap a suggestion to open or prefill composer; tap a calendar item to open Planner thread.

### Cards / Containers
- **Message bubbles:** User right-aligned, accent fill, 12pt radius, max width 600pt. Assistant left-aligned with small avatar, 12pt radius, control background, 1pt subtle border.
- **Activity panel:** Collapsible section above composer in chat view; same control background; status dots (gray pending, blue in progress, green complete, red failed).
- **Memory notice:** Inline banner in chat after silent memory write: "Memory updated" with link to Settings Memory panel.
- **Sidebar rows:** Plain list selection highlight; agent badge and source badge (desktop / iMessage) as small labels.

### Inputs / Fields
- **Composer (home):** Slim single-line or 2-line field at bottom of briefing dashboard. Placeholder: "Ask a follow-up..."
- **Composer (chat):** Multi-line TextEditor in rounded container (16pt radius), 2-8 lines auto-grow. Placeholder: "Ask anything, search the web, check your calendar..."
- **Settings:** Native Form in Settings scene; SecureField for API keys with rounded border style; Memory panel with editable profile and undo list.

### Navigation
- **Sidebar:** NavigationSplitView, 240pt fixed width, + button for new chat (with agent picker sheet), conversation list grouped by date.
- **Home (detail, no thread selected):** Briefing dashboard fills detail column; slim composer pinned to bottom.
- **Chat (detail, thread selected):** Message thread + activity panel slot + full composer.
- **Header (chat detail):** Agent name, agent chip, source badge (iMessage), model status dot. Settings open via menu bar or ⌘, (native Settings scene). No workspace folder gate.
- **Menu bar:** MenuBarExtra with bubble icon (not sparkles); menu items for Open briefing, New chat, Recent, Settings, Quit. Login item on by default; Dock hidden by default.

## Do's and Don'ts

### Do:
- **Do** use NavigationSplitView with conversation history in the sidebar and briefing or chat in the detail column.
- **Do** center the content column at 720pt max width for comfortable reading.
- **Do** show yesterday recap and today suggestions before the user types anything.
- **Do** use SF Pro body text for assistant replies, briefing prose, and SF Mono only inside code blocks.
- **Do** respect light and dark mode via semantic system colors.
- **Do** separate desktop and iMessage conversations visually (source badge or dedicated grouping).
- **Do** let the user pick an agent when creating a new thread; show agent name in chat header.
- **Do** keep the composer slim on the home briefing screen; expand to full composer in chat view.

### Don't:
- **Don't** use the empty chat prompt ("What can I help with?") as the primary home screen.
- **Don't** use blue-to-purple gradient fills on user bubbles (current prototype anti-pattern).
- **Don't** render assistant messages in monospaced font (reads as a coding tool).
- **Don't** block briefing or chat behind "Open Workspace" or folder selection.
- **Don't** embed settings inline where they displace content (use Settings scene).
- **Don't** adopt Cursor/IDE dark themes, terminal-green accents, or file-tree chrome as the main layout.
- **Don't** use sparkle-heavy branding, glassmorphism panels, or neon purple accents as default decoration.
- **Don't** use coding-centric placeholder copy ("write code", "run tests") as the primary prompt.
- **Don't** show agent switching controls inside an active thread in v1.
