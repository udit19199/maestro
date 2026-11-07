# New chat walkthrough

Full app path from Home to first message. Read-only by default; sending needs approval and backup.

## Sub-features

- `new-chat-open`: Home shows sidebar and New Chat entry.
- `first-message`: one approved message sends and persists.

## How to get to it (user POV)

- Open Maestro, go to Home.
- Open New Chat, pick the bot, send one message.
- The reply streams and the chat stays in the sidebar after restart.

## Driving it

Preconditions: doctor passes, `check-bot-chats.sh` green, backup recorded for a mutating run.

- Action: open Home and New Chat, screenshot each.
  - Result: sidebar, composer, and bot picker visible.
- Action (only if approved): send one short message, wait for settle, screenshot the reply.
  - Result: reply text visible, chat id recorded.
- Action: read back persistence.
  - Command: `python3 -c "import json; d=json.load(open('$HOME/Library/Application Support/Maestro/conversations.json')); print(len(d))"` (adjust shape to `ConversationStore.swift`)
  - Result: the new chat id is present.

## Gotchas

- Never run two copies. Quit first, then verify.
- Quitting stops all pi sessions by design (`AppDelegate`).
- Without provider sign-in this recipe is blocked at Settings. Report it, do not fake it.
