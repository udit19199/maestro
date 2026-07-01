# Zoro

Native macOS personal AI assistant built with SwiftUI and Apple's `FoundationModels` framework. Briefing-first home, specialized agents, persistent conversations, and optional file/shell tools.

## Requirements

- macOS 27.0+
- Xcode 26.x+ on a Mac with Apple Intelligence support (or configure Claude, Gemini, OpenAI, or Codex in Settings)
- Full Disk Access (only if using iMessage remote commands)

## Build and run

1. Open `zoro.xcodeproj` in Xcode.
2. Select the **zoro** scheme and a macOS destination.
3. Build and run (⌘R).
4. On first launch, open **Settings** (⌘,) and configure a model backend. Attach a workspace folder under **Workspace** only if you need file or terminal tools.

## Tests

Run unit tests with ⌘U in Xcode on macOS. The `zoroTests` target includes Gmail parsing and Codex auth/request tests.

## Documentation

| Document | Purpose |
|---|---|
| [PRODUCT.md](./PRODUCT.md) | Product vision, agents, flows, non-goals |
| [DESIGN.md](./DESIGN.md) | Visual system and UI components |
| [.agents/AGENTS.md](./.agents/AGENTS.md) | Architecture, conventions, and agent integration guide |
| [reference/gmail-setup.md](./reference/gmail-setup.md) | Gmail OAuth setup (backend wiring pending) |
| [MISSION.md](./MISSION.md) | Codebase learning mission |

## Project layout

```
zoro/           Swift app source (Views/, Services/, Models/, tools)
zoroTests/      Unit tests
zoro.xcodeproj/ Xcode project (SPM: ClaudeForFoundationModels 0.1.2)
lessons/        HTML curriculum for learning the codebase
```

## Remote iMessage commands

Whitelisted senders can text:

```
zoro: [passcode ]research:|plan:|teach: <command>
```

Passcode is optional. Each command starts a new conversation.

## Limitations

- Cannot be built on Linux or in cloud agent VMs (Apple-only frameworks).
- Gmail integration backend exists; agent registration and Settings UI are not wired yet.
