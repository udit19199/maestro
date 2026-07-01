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

Run unit tests with ⌘U in Xcode on macOS. The `zoroTests` target covers Gmail parsing and Codex auth/request helpers.

## Documentation

| Document | Purpose |
|---|---|
| [docs/PRODUCT.md](./docs/PRODUCT.md) | Product vision, agents, flows, non-goals |
| [docs/DESIGN.md](./docs/DESIGN.md) | Visual system and UI components |
| [.agents/AGENTS.md](./.agents/AGENTS.md) | Architecture, conventions, and agent integration guide |
| [reference/gmail-setup.md](./reference/gmail-setup.md) | Gmail OAuth setup (backend wiring pending) |

## Project layout

```
zoro/
├── App/                 Entry point (zoroApp, AppDelegate)
├── Views/               SwiftUI screens and components
├── Services/            AgentRunner, stores, briefing, prompts
├── Models/              Conversation, messages, agent types
├── Tools/               FoundationModels tool implementations
├── Integrations/
│   ├── Gmail/           OAuth, REST client, manage_gmail tool
│   └── IMessage/        Remote listener and send tool
├── LanguageModels/      OpenAI, Gemini, Codex backends
├── Support/             Keychain, WorkspaceManager
└── Assets.xcassets

zoroTests/
├── Gmail/
└── Codex/

docs/                    Product and design specs
reference/               Integration setup guides
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
