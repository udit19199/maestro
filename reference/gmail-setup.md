# Gmail Setup Guide

Zoro connects to Gmail via **OAuth 2.0** (desktop app flow). No Google SDK is required — Zoro uses the Gmail REST API directly with tokens stored in the macOS Keychain.

## 1. Google Cloud Console

1. Open [Google Cloud Console](https://console.cloud.google.com/).
2. Create a project (or select an existing one).
3. Enable **Gmail API**: APIs & Services → Library → search "Gmail API" → Enable.
4. Configure **OAuth consent screen**:
   - User type: External (for personal Gmail) or Internal (Workspace only).
   - Add scopes: `gmail.readonly`, `gmail.send`, `gmail.modify` (Zoro requests all three).
   - Add yourself as a test user if the app is in Testing mode.
5. Create credentials: APIs & Services → Credentials → **Create Credentials → OAuth client ID**.
   - Application type: **Desktop app**
   - Name: e.g. `Zoro macOS`
6. Copy the **Client ID** and **Client Secret**.

## 2. Redirect URI

In the OAuth client settings, add this authorized redirect URI:

```
http://127.0.0.1:8765/
```

Zoro starts a local callback server on port **8765** during Connect Gmail.

## 3. Connect in Zoro

> **Note:** Gmail backend supports **multiple accounts** via `MailAccountStore`. Settings UI for add/disconnect is **not yet wired**.

1. Open Zoro → open **Settings** (⌘, or menu bar → Settings…).
2. Go to the **Gmail Integration** section (pending implementation in `SettingsView.swift`).
3. Paste **Client ID** and **Client Secret** (saved to Keychain as shared OAuth app credentials).
4. Click **Connect Gmail** — your browser opens for Google sign-in.
5. Repeat step 4 to add additional Gmail accounts. Only one OAuth flow runs at a time on port 8765.
6. After approval, return to Zoro. When wired, Settings will list each connected account.

Until the Settings UI ships, OAuth credentials can only be configured once the Gmail section is added to Settings.

See [mail-setup.md](mail-setup.md) for multi-account Keychain schema and migration notes.

## 4. Verify

Try these prompts:

- *"How many unread emails do I have?"* → should call `get_status`
- *"List my 5 most recent inbox emails"* → `list_messages` (index only)
- *"Read and summarize the latest email from [sender]"* → `search_messages` then `read_message` or `read_thread`

## Architecture (for maintainers)

| File | Role |
|---|---|
| `zoro/Integrations/Gmail/GmailAuthManager.swift` | Multi-account OAuth flow, per-account token refresh, Keychain storage |
| `zoro/Integrations/Gmail/GmailService.swift` | Gmail REST API client (per `accountId`), pagination, fetch reports |
| `zoro/Integrations/Mail/GmailMailProvider.swift` | `MailProvider` adapter for Gmail |
| `zoro/Integrations/Mail/MailAccountStore.swift` | Account registry and legacy token migration |
| `zoro/Integrations/Gmail/GmailManager.swift` | Inbox snapshot, activity log, agent context injection |
| `zoro/Integrations/Gmail/GmailTool.swift` | `manage_gmail` tool exposed to the LLM |
| `zoro/Integrations/Gmail/GmailReadAuditor.swift` | Tracks index vs full reads (response blocking not yet wired in chat) |
| `zoro/Tools/SecurityPolicy.swift` | Gmail limits (page size, batch read, body bytes, retries) |

**Wiring status:** `GmailTool` is not yet registered in `AgentRunner.tools(for:)`. Session instructions from `GmailManager.contextualInstructions()` are not yet injected in `AgentRunner.getOrCreateSession()`. Settings UI and header/inbox preview are pending.

## Anti-hallucination model

1. **Search/list** returns an **index** (metadata + snippets) — not sufficient for summarization.
2. **read_message / read_messages / read_thread** returns **full bodies** with `body_complete: true/false`.
3. Every response includes a **GMAIL FETCH REPORT** with `fetch_complete` and warnings.
4. When Gmail is connected, **session instructions** inject mandatory rules (never invent IDs, always read before summarizing).

## iMessage remote sessions

Remote `zoro:` commands can **read/search** Gmail but cannot **send** or **trash** messages.

## Troubleshooting

| Issue | Fix |
|---|---|
| "Could not bind to port 8765" | Another app is using the port. Quit it and retry. |
| Redirect URI mismatch | Ensure Google Console has exactly `http://127.0.0.1:8765/` |
| "Access blocked" on consent screen | Add your Google account as a test user (Testing mode) |
| Token refresh fails | Disconnect and reconnect Gmail; re-authorize with `prompt=consent` |
| Agent summarizes from snippets | Chat-level blocking is not wired yet — ensure the agent calls `read_*` before summarizing; auditor records reads inside `GmailTool` only |

## Hard read enforcement

When fully wired, Zoro will block assistant responses that summarize email without calling `read_message`, `read_messages`, or `read_thread` first. Today, `GmailReadAuditor` records reads inside `GmailTool` only; chat-level blocking in `ChatView` and `IMessageListener` is pending.

## Known limits

- **250 messages** max per search/list when `fetchAll: true` (configurable in `SecurityPolicy`)
- **20 messages** max per `read_messages` batch
- **Text + PDF attachments** via `read_attachment` — images not yet supported
- **Inbox auto-refresh** every 5 minutes when connected (manual refresh also available)
- **No background push** — uses on-demand fetch + periodic snapshot refresh
