---
name: verify-maestro
description: Verify Maestro native macOS app through full app walkthrough and isolated logic check. Use when a change needs proof in the running app.
---

# Verify Maestro

Prove behavior in two layers. The automated layer runs isolated with a temp home and never touches your real chats. The full app layer opens the real window. Default to read-only in the live app. Send a message only with explicit approval.

Read [the feature map](features/README.md) before driving.

## Launch

Automated layer needs no app launch:

```sh
mkdir -p /tmp/verify-maestro
VERIFY_DIR="$(mktemp -d /tmp/verify-maestro/XXXXXX)"
```

Full app layer:

1. Open `maestro.xcodeproj`, select the `maestro` scheme, build and run (Cmd+R). Requires macOS 27+, Xcode, Node 22.19+, pi 1.2.0.
2. First launch goes to Settings: Relay must answer on 127.0.0.1:8317; pick a default model from the pi catalog.
3. Create a bot conversation from Home or New Chat.

Never launch two copies at once. Both share `~/Library/Application Support/Maestro/conversations.json` and quit stops all pi sessions.

## Doctor

- Scheme exists: `xcodebuild -list -project maestro.xcodeproj` shows `maestro`.
- pi runtime present: `~/Library/Application Support/Maestro/pi/runtime` exists (the check script symlinks it; `pi` is not on PATH by design). If missing, install pi 1.2.0 per README and stop here as blocked.
- No other Maestro running for a mutating run: `pgrep -x Maestro` prints nothing. If one runs, stay read-only.
- For a mutating full app run: back up `~/Library/Application Support/Maestro/conversations.json` first and record the backup path.
- If sign-in or model catalog is missing, stop. Report blocked, do not work around auth.

## Drive

Prefer the isolated check. It keeps credentials and writes in a temp home and reuses only the installed pi runtime:

```sh
bash scripts/check-bot-chats.sh
bash scripts/check-mail.sh
```

Expect `PASS:` lines. `check-bot-chats.sh` proves bot selection, persistence, a live hand-off, a group @mention, and pi catalog reachability. `check-mail.sh` proves the mail and calendar tools fail safely and that a denied approval stops a send. Neither touches real data.

Full app walkthrough is manual and read-only by default: Home → conversation sidebar → New Chat sheet → Settings providers, MCP Notion, and Mail and Calendar. Take screenshots at each stop. Do not send messages, delete chats, or connect Notion unless the run explicitly approved mutation and the backup from Doctor exists.

## Evidence

- Keep the full `check-bot-chats.sh` stdout (PASS lines) under `$VERIFY_DIR/`.
- Keep window screenshots outside the repo, under `$VERIFY_DIR/`.
- For a mutating run, read back `conversations.json` (or its backup diff) and the pi session dir for the chat id. Record the chat id with every artifact.
- A green build alone is not app proof.

## Cleanup

- The isolated check cleans its own temp dir except what you copied to `$VERIFY_DIR`. Keep `$VERIFY_DIR`.
- For a mutating full app run, restore the backup or name the new chat that remains. Never kill by process name; quit the app normally so pi sessions stop cleanly.
- Confirm evidence still exists under `$VERIFY_DIR/` after cleanup.

## Features

- [New chat walkthrough](features/new-chat.md)
- [Group chats](features/groups.md)
- [Providers and models](features/providers.md)
- [Bot persistence check](features/bot-persistence.md)
