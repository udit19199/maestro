# Zoro

Native macOS personal AI assistant built with SwiftUI and Apple's `FoundationModels` framework. Briefing-first home, specialized agents, persistent conversations, and **human-in-the-loop** controls for irreversible actions.

## Requirements

- macOS 27.0+
- Xcode 26.x+ on a Mac with Apple Intelligence support (or configure OpenAI or Codex in Settings)
- Full Disk Access (only if using iMessage remote commands)

## Build and run

1. Open `zoro.xcodeproj` in Xcode.
2. Select the **zoro** scheme and a macOS destination.
3. Build and run (⌘R).
4. On first launch, open **Settings** (⌘,) and configure a model backend. Attach a workspace folder under **Workspace** only if you need file or terminal tools.

## Safety model (deterministic)

Side effects are enforced in **Swift code**, not system prompts:

| Action | Behavior |
|--------|----------|
| Send email | Draft only → **Confirm** in app bar |
| Send iMessage | Staged → **Confirm** in app bar |
| Shell command | Staged → **Run** in app bar |
| Create calendar event / reminder | Staged → **Confirm** in app bar |
| Delete event / complete reminder | Staged → **Confirm** in app bar |
| Remote iMessage session | Read-oriented tools only; no free-fire send/shell/memory |
| Workspace paths | Symlink-safe containment + security-scoped bookmarks |

Leave **iMessage Command Listener** off unless you need remote access. Whitelist at least one sender; passcode is optional but recommended.

## Tests

Run unit tests with ⌘U in Xcode on macOS (`zoroTests`: mail, Gmail parsing, Codex, **SecurityPolicy**).

## Documentation

| Document | Purpose |
|---|---|
| [docs/PRODUCT.md](./docs/PRODUCT.md) | Product vision, agents, flows, non-goals |
| [docs/DESIGN.md](./docs/DESIGN.md) | Visual system and UI components |
| [.agents/AGENTS.md](./.agents/AGENTS.md) | Architecture, conventions, and agent integration guide |
| [reference/mail-setup.md](./reference/mail-setup.md) | Multi-account mail setup |
| [reference/gmail-setup.md](./reference/gmail-setup.md) | Gmail OAuth setup |

## Remote iMessage commands

Whitelisted senders can text:

```
zoro: [passcode ]research:|plan:|teach: <command>
```

Each command starts a new conversation bound to that sender. Model-initiated outbound texts still require on-Mac confirmation; system replies to the requester use an app-controlled path.

## Limitations

- Cannot be built on Linux or in cloud agent VMs (Apple-only frameworks).
- Notes create/append still apply immediately on desktop (denied over remote).
