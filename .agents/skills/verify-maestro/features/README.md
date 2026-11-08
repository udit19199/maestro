# Maestro verification map

Two layers. The isolated check runs headless in a temp home. The full app layer opens the real window and defaults to read-only.

## Baseline preconditions

- Repo checkout builds: `maestro` scheme in `maestro.xcodeproj`.
- pi 1.2.0+ installed. Provider sign-in done in the live app before any mutating run.
- No second Maestro copy running during a mutating run.
- Evidence goes to `/tmp/verify-maestro/<run-id>/` and survives cleanup.

## Driving conventions

- Start with [the verifier instructions](../SKILL.md), including its doctor.
- Run `scripts/check-bot-chats.sh` before any full app mutation. If it fails, stop.
- In the live app, walk Home, sidebar, New Chat, Settings. Read only unless mutation was approved and a backup exists.
- One chat id per mutating run. Record it with every artifact.

## Proof and skip reporting

- Isolated proof: full `check-bot-chats.sh` stdout with PASS lines.
- App proof: screenshots of each stop plus the persisted chat record.
- Report a missing sign-in or running copy as blocked with the exact check that failed.

## Features

- [New chat walkthrough](./new-chat.md) covers the full app path Home to first message.
- [Group chats](./groups.md) covers @mentions, whole-name matching, and changing members.
- [Providers and models](./providers.md) covers Settings catalog and model pick.
- [Bot persistence check](./bot-persistence.md) covers the isolated script and migration.
