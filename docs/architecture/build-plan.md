# Build plan

From today's app (current-state.md) to this design. Each step is one PR that leaves `main` working.

## 1. Order

| # | PR | Done when |
|---|---|---|
| 0 | **Spikes** for assumptions A1–A6 (operations.md §6), in a scratch folder, results written into requirements.md §6 | Each assumption marked held or failed, with numbers |
| 1 | **Core skeleton**: `core/` package, TypeBox types matching `types/`, JSON Schema export, stdio JSON-RPC server, `hello`/`shutdown`, store with schema.sql and migrations | Core starts, answers `hello` with an empty snapshot; store tests pass |
| 2 | **Workspace loader**: bot and routine files, validation, watching, `.claude` links | Invalid files report per-field errors; edits show up live |
| 3 | **Runs on pi SDK**: sessions, episodes, run queue, event mapping, direct threads, faux-provider tests | A direct thread streams a reply end to end over the protocol |
| 4 | **Shell on the core**: Swift generated types, `CoreClient`, snapshot cache, history paging; old `PiSessions` path removed | The app does today's direct chats through the core |
| 5 | **Groups and hand-offs**: routing, `seen_seq`, `message_bot`, task threads, hop and run budgets | Group @mentions and hand-offs work as today, plus limits |
| 6 | **Gate and proposals**: effect table, policy, proposals, holds, undo, receipts | A sweep labels without asking and proposes sends; crash tests for §2 pass |
| 7 | **Mail**: Gmail over IMAP/SMTP with app password, sync and cache | App-password sign-in in under 2 minutes; every mail tool works |
| 8 | **Calendar through host requests** | Calendar tools work with the grant; clear message without it |
| 9 | **Memory, ledger, recall, carry-over** | The ledger block shows a promise from another thread; audience rule tests pass |
| 10 | **Routines** | 08:00 routine runs with the window closed; missed-run rules hold |
| 11 | **iMessage channel** | Self-chat replies and reply-to routing work from an iPhone |
| 12 | **Packaging**: bundled Node, signing, first-run setup | A clean Mac runs the app with no Node installed |

Steps 7–9 can go in any order after 6. Step 11 needs 9.

## 2. Migrating data

- `conversations.json` → threads (direct or group, by member count) and messages, one episode each, marked imported.
- `bots/<id>/definition.json` → `~/Maestro/.agents/agents/<id>.md`; the old files are copied to `~/Workspace/local/maestro/backup-<date>/` first.
- Old pi session folders are not carried over. The first new message in an imported thread opens a new episode with a carry-over built from the imported transcript.
- `mail.json` app password → Keychain, then the file is removed (after the user's yes).

## 3. What gets deleted from today's code

`PiRPC.swift`, `PiSessions.swift`, `PiProtocol.swift`, `ConversationStore.swift`'s JSON persistence and `maestro-pi.ts` once their steps land. `MacCalendar.swift` stays as the EventKit side of host requests.
</content>
