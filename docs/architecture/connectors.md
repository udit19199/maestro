# Connectors

## 1. What each connector gives bots

| Connector | Tools | Backed by |
|---|---|---|
| Mail | `mail_search`, `mail_read`, `mail_thread`, `mail_label`, `mail_draft`, `mail_send`, `mail_reply`, `mail_trash` | Gmail API (Google sign-in) or IMAP/SMTP (app password) |
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

## 2. Google sign-in

### 2.1 How others do it (checked 27 Nov 2026)

| Product | How Gmail access works |
|---|---|
| Hermes Agent | Each user makes their own Google Cloud project and a "Desktop app" OAuth client, then pastes the client id and secret (hermes-agent docs, google-workspace skill `setup.py`). About 10 minutes of setup |
| dusk.bot | Gmail goes through Composio, a third party that holds the OAuth tokens, or through an app password over IMAP. Its own "Sign in with Google" asks only for name and email (`docs/composio.md`, `apps/dashboard/server/auth/providers.ts`) |
| Relay | Signs in to Claude, Codex and xAI with those vendors' own CLI client ids. It has no Google sign-in |

### 2.2 What Maestro does

Google treats a desktop app as an **installed app**: the client id and secret are embedded in the app, and "the client secret is obviously not treated as a secret" (developers.google.com/identity/protocols/oauth2, "Installed applications"). So a one-click sign-in needs **no backend**:

1. Maestro ships a Desktop OAuth client id and secret from a Google Cloud project Maestro owns (open question Q1).
2. The user clicks **Sign in with Google**. The core starts a listener on `127.0.0.1:<random port>`, makes a PKCE pair, and asks the shell to open Google's consent page (`browser.open`) with redirect `http://127.0.0.1:<port>`.
3. The user picks the account. Google shows "Google hasn't verified this app"; they click **Advanced → Go to Maestro**, then allow access.
4. Google redirects to the loopback listener with a code. The core exchanges it for tokens, stores the refresh token in Keychain (`keychain.set`), and closes the listener.
5. The core calls Gmail `users.getProfile` to read the address, creates the `connections` row, and starts sync.

What the user sees: one button, a browser tab, one warning click, done.

Scopes: `openid email https://www.googleapis.com/auth/gmail.modify`. `gmail.modify` covers read, label, draft and send, and does not allow permanent deletion (Gmail API scopes page). So `mail_trash` moves to Trash only.

### 2.3 Other paths

| Path | For | Setup |
|---|---|---|
| **Own client** | Anyone who forks Maestro, anyone after the 100-user cap, anyone who does not want the warning screen | Make a Google Cloud project in **Personal mode** (only the creator's account; no verification and no warning screen), add a Desktop client, paste id and secret in Settings. Same flow as §2.2 with their client |
| **App password** | Users who will not touch Google Cloud, and non-Gmail IMAP accounts | Turn on 2-step verification, make an app password, paste it. IMAP/SMTP over TLS. No Gmail labels API (uses IMAP folders and flags), no history sync (uses IMAP IDLE plus UID polling) |

### 2.4 Google's limits

- An unverified app with restricted scopes (Gmail) works for **fewer than 100 users**, each clicking past the warning (Google Cloud help, "When is verification not needed").
- Past 100 users, the app needs verification, which for restricted scopes includes a yearly security assessment by a Google-approved assessor (Google Cloud help, "Verification requirements" §5).
- The project must be **In production**, not **Testing**: a Testing app's refresh tokens expire after 7 days (oauth2 docs, "Refresh token expiration").
- At most 100 live refresh tokens per Google account per client; more and the oldest stops working. Maestro keeps one per account.

So: the shipped client is fine while Maestro has under 100 users. When that is close, either verify, or make "own client" the default and keep the shipped one for existing users.

### 2.5 Token handling

- Access tokens live in memory. The core refreshes 5 minutes before expiry, and once on a 401 (then retries the call once).
- If Google refuses the refresh token, the connection becomes `needs_reconnect`, mail tools answer "Gmail needs you to sign in again", and Today shows a reconnect row. Reconnecting keeps the same `connectionId`.

## 3. Mail sync and cache

- Gmail API: on start and every 60 s, `users.history.list` from the stored `historyId`; changed messages' headers go into `mail_messages`. If the history id is too old (404), a full resync of the last 90 days of headers.
- IMAP: IDLE on INBOX, with a UID poll every 5 minutes for other folders.
- Bodies are fetched on `mail_read` and kept 14 days (`mail_bodies`).
- New-mail routine triggers come from sync (routines.md §2).
- Mail search goes to Gmail; results fill the cache. Tools read headers from the cache when they can.

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
| Google refresh tokens | Keychain `ai.maestro` / `google:<connectionId>` | Core, at start, via `keychain.get` |
| IMAP app passwords | Keychain `imap:<connectionId>` | Core |
| Model API keys | Keychain `model:<provider>` | Core, set into pi with `ModelRuntime.setRuntimeApiKey` |
| MCP env and headers | Keychain `mcp:<name>` | Core, when starting the server |

- Secrets never go into SQLite, logs, events, tool results or bot context.
- pi's `auth.json` is not used for API keys. Its path points into the state folder and holds only OAuth state pi needs for MCP and subscription providers, with mode 0600; moving those into Keychain too is a follow-up once pi exposes an auth storage hook.
</content>
