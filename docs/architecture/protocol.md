# Core ↔ shell protocol

Types: [types/protocol.ts](types/protocol.ts). Version 1.

## 1. Transport

- The shell starts the core and talks to it over the core's **stdin and stdout**. One JSON object per line, UTF-8, `\n` only. A line may be long; neither side assumes a maximum.
- **stderr** is the core's log stream. The shell copies it to `logs/core.log` and never parses it.
- JSON-RPC 2.0 in both directions. Shell request ids are odd, core request ids are even.
- No socket, no port. Nothing else on the Mac can talk to the core (security.md §2).

Why stdio and not a socket: the shell is always the parent (system.md §1), stdio needs no auth, and a crash closes the pipe, which both sides notice at once.

## 2. Three kinds of message

| Kind | Direction | JSON-RPC form | Names |
|---|---|---|---|
| Command | shell → core | request, gets a response | `ShellCommands` |
| Event | core → shell | notification `event` with an `EventEnvelope` | `CoreEvent` |
| Host request | core → shell | request, gets a response | `HostRequests` |

## 3. Connect and snapshot

1. The shell's first message is `hello`. Any other command before it gets `-32600`.
2. If `protocolVersion` differs from the core's, the core answers error `1004` and exits. Shell and core ship in one bundle, so this only happens in development.
3. The `hello` result is a `Snapshot`: everything the shell needs to draw every screen except message history, which it pages with `thread.history`.
4. `Snapshot.seq` is the last event number already reflected in it. The first event after it has `seq + 1`.

The shell stores the snapshot in `shell/snapshot.json` and paints from it at the next launch before `hello` returns.

## 4. Events

- Every event has `seq`, increasing by one, starting at 1 in each core process. A gap means a bug: the shell logs it and asks for a fresh snapshot by sending `hello` again.
- Events are sent after the transaction that caused them commits (invariant 9). So the response to a command can arrive after the events it caused. The shell applies events and ignores the response's copy if it already has a newer one (compare `updatedAt` or the status order).
- `*.upserted` events carry the whole object. The shell replaces its copy. There are no partial patches except `run.text`.
- `run.text` carries only new text. The core merges deltas and sends at most one per run every 33 ms. While a run is running, the shell's `RunSummary.textSoFar` plus later deltas is the whole text. `run.ended` points at the final message, whose text wins.
- `run.tool` is sent when a call starts (`status: running`) and again when it ends.

Order guarantee: events for one thread arrive in the order their transactions committed. There is no order guarantee across threads, and the shell must not need one.

## 5. Host requests

The core sends a host request when it needs something only the app bundle can do: Keychain, EventKit, Messages, opening a browser, a notification.

- The shell answers within 30 s or the core treats it as failed. Calendar and Messages calls the user must grant show the macOS prompt the first time; the shell answers after the prompt.
- If the shell cannot do it now (no permission), it answers `1006` with a readable message. The core maps that into the tool result ("Calendar access is off. Turn it on in System Settings > Privacy > Calendars.") and into `Health`.
- At start, the core gets every secret it needs with `keychain.get` and keeps it in memory only (connectors.md §6).

## 6. Errors

- A command that fails its schema check gets `-32602` with the field path in `data.field`.
- `1002 conflict` means the state moved: approving an action someone else (a hold timer, an expiry) already moved. The shell refreshes that object from the next event.
- `1003 invalid_state` means the request is never allowed in this state, for example undoing an action whose connector has no inverse.
- Error `message` text is shown to the user as is. It is one plain sentence.

## 7. Idempotency

- `message.send` carries a `clientId` the shell makes. Sending the same `clientId` twice returns the first result. This lets the shell resend after a core restart without doubling a message.
- `action.approve`, `action.deny` and `action.undo` are compare-and-set on the action's status, so a double press is a `1002`, never a double send.

## 8. One source for the types

1. The core defines every type in TypeBox, the schema library pi already uses. `types/*.ts` in this folder is the reviewed copy and must match.
2. A build step writes JSON Schema for `ShellCommands`, `CoreEvent`, `Snapshot` and `HostRequests` to `core/schema/protocol.json`.
3. The Swift `Codable` types are generated from that file (quicktype) into `maestro/Core/Protocol.generated.swift`. Nobody edits that file by hand.
4. The core validates every incoming line against the schema. The shell trusts the core's output, because both ship in one bundle; a contract test checks generated Swift decodes recorded core output (operations.md §5).

Tagged unions use a `type` or `kind` field and map to Swift enums with associated values.

## 9. Example

```json
→ {"jsonrpc":"2.0","id":7,"method":"message.send","params":{"threadId":"thr_01JD…","text":"@mail any replies from Priya?","attachments":[],"clientId":"c-41"}}
← {"jsonrpc":"2.0","method":"event","params":{"seq":120,"at":"2026-11-27T08:01:02.110Z","event":{"type":"message.added","message":{…}}}}
← {"jsonrpc":"2.0","method":"event","params":{"seq":121,"at":"…","event":{"type":"run.queued","run":{…}}}}
← {"jsonrpc":"2.0","id":7,"result":{"messageId":"msg_01JD…","runIds":["run_01JD…"]}}
← {"jsonrpc":"2.0","method":"event","params":{"seq":122,"at":"…","event":{"type":"run.started",…}}}
← {"jsonrpc":"2.0","method":"event","params":{"seq":123,"at":"…","event":{"type":"run.tool","runId":"run_01JD…","call":{"tool":"mail_search","label":"Searching mail: from Priya, last 7 days","status":"running",…}}}}
```
</content>
