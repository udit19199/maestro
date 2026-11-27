# Connectors

## 1. What each connector gives bots

| Connector | Tools | Backed by |
|---|---|---|
| Mail | `mail_search`, `mail_read`, `mail_thread`, `mail_label`, `mail_draft`, `mail_send`, `mail_reply`, `mail_trash` | Gmail over IMAP/SMTP with an app password |
| Calendar | `calendar_list`, `calendar_events`, `calendar_create`, `calendar_update`, `calendar_delete`, `calendar_respond` | EventKit, through the shell. Google calendars show up if the user added the Google account to macOS |
| Messages | `messages_send` | Messages.app, through the shell (channels.md) |
| MCP | Whatever the server offers | pi's MCP extension, one client per server |
| Models | — | pi providers: Relay, Anthropic, OpenAI, any OpenAI-compatible URL |

Every connector implements one interface per kind, so a bot's tools do not change when the backend does:

```ts
interface MailBackend {
  search(q: string, limit: number): Promise<MailHeader[]>;
  read(ref: string): Promise<MailBody>;
  thread(threadRef: string): Promise<MailHeader[]>;
  label(op: MailLabelOp, refs: string[], labels: string[]): Promise<void>;
  draft(d: MailDraft): Promise<{ ref: string }>;
  send(d: MailDraft): Promise<{ ref: string; link: string | null }>;
  trash(refs: string[]): Promise<void>;
  sync(cursor: string | null): Promise<{ changed: MailHeader[]; removed: string[]; cursor: string }>;
}
```

## 2. Mail sign-in

v1 is Gmail over IMAP/SMTP with an app password, for the owner's own account (decision D10). No Google Cloud project, no OAuth client, no server.

1. The user turns on 2-step verification and makes a Google app password.
2. In Settings they paste the address and the app password (`connection.imapAdd`).
3. The core logs in to `imap.gmail.com:993` and `smtp.gmail.com:465` over TLS, stores the password in Keychain, creates the `connections` row and starts sync.
4. If the login fails, the connection becomes `needs_reconnect` with Gmail's own refusal text, and Today shows a reconnect row.

Gmail over IMAP: labels are IMAP folders (`X-GM-LABELS` where the server allows it), Trash is `[Gmail]/Trash`, search uses `X-GM-RAW` so Gmail search syntax works.

### 2.1 Later, not v1

- **Google OAuth (Gmail API)** with each user's own Desktop client: Hermes's model (each user makes a Google Cloud project). Only when other users need it.
- A Maestro-owned shared client is rejected: the maintainer would own a project, and past 100 users Google needs verification and a yearly security assessment.
- Composio and other token brokers are rejected: a third party would hold the Gmail login.

## 3. Mail sync and cache

- IDLE on INBOX, with a UID poll every 5 minutes for other folders.
- Bodies are fetched on `mail_read` and kept 14 days (`mail_bodies`).
- New-mail routine triggers come from sync (routines.md §2).
- Mail search goes to Gmail (`X-GM-RAW`); results fill the cache. Tools read headers from the cache when they can.

## 4. Calendar

- EventKit in the shell, through host requests `calendar.list`, `calendar.events`, `calendar.apply`.
- The shell asks for full calendar access the first time a calendar tool runs, not at launch.
- Event refs are EventKit `calendarItemExternalIdentifier`s, stable across devices.
- `calendar_respond` maps to EventKit participant status where the calendar allows it; where it does not, the tool says so.

## 5. MCP servers

- Configured in `~/Maestro/.agents/mcp.json` (Claude Desktop `mcpServers` format, which pi reads), plus Maestro's `maestro.effects` per server (permissions.md §2).
- A bot uses only the servers its file lists in `maestro.mcp`.
- Secrets in `env` or headers are written as `"${keychain:notion}"`; the core fills them from Keychain when it starts the server. A literal secret in the file is accepted but Settings warns.
- MCP OAuth (remote servers) uses pi's built-in flow; pi keeps those tokens in its auth file in the state folder (§6).

## 6. Secrets

| Secret | Where | Who reads it |
|---|---|---|
| IMAP app passwords | Keychain `imap:<connectionId>` | Core |
| Model API keys | Keychain `model:<provider>` | Core, set into pi with `ModelRuntime.setRuntimeApiKey` |
| MCP env and headers | Keychain `mcp:<name>` | Core, when starting the server |

- Secrets never go into SQLite, logs, events, tool results or bot context.
- pi's `auth.json` is not used for API keys. Its path points into the state folder and holds only OAuth state pi needs for MCP and subscription providers, with mode 0600; moving those into Keychain too is a follow-up once pi exposes an auth storage hook.
</content>
