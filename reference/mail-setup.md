# Mail Setup Guide

Zoro supports multiple mail accounts through a unified `MailProvider` boundary. Gmail uses OAuth; IMAP accounts (Namecheap Private Email, iCloud) use app-specific or mailbox passwords.

See also: [gmail-setup.md](gmail-setup.md) for Google Cloud Console steps and [mail-architecture.md](mail-architecture.md) for layer design.

## Quick start

1. Open Zoro → **Settings** (⌘,) → **Mail** tab.
2. Add at least one account (Gmail OAuth or IMAP preset).
3. Return to the briefing home — the **Inbox** section syncs unread mail across accounts.
4. Ask the General agent about mail (e.g. *"How many unread emails do I have?"*) — it uses the `manage_mail` tool.

## Settings Mail tab

`SettingsView` → **Mail** tab (`SettingsMailAccountsSection`):

| Section | What to configure |
|---|---|
| **Gmail OAuth App** | Shared Google Client ID and Client Secret (Keychain: `gmail_client_id`, `gmail_client_secret`) |
| **Gmail Accounts** | **Add Gmail Account** — browser OAuth on port **8765**; disconnect per account |
| **IMAP Accounts** | **Add IMAP Account** — Namecheap Private Email or iCloud preset |
| **Sync** | **Sync All Accounts** — manual refresh; per-account sync status |
| **Weekly Cleanup** | Toggle Sunday review; archive batch for old newsletters |

After connect or disconnect, Zoro invalidates agent sessions so `manage_mail` rules apply immediately.

## Multi-account Gmail

- OAuth app credentials (`gmail_client_id`, `gmail_client_secret`) are shared across all Gmail accounts.
- Per-account tokens are stored in Keychain as `mail_gmail_refresh_<accountId>`, `mail_gmail_access_<accountId>`, `mail_gmail_expiry_<accountId>`.
- Account metadata lives in `~/Library/Application Support/Zoro/mail_accounts.json`.
- Adding a Gmail account runs the same desktop OAuth flow on port **8765** — only one authorization at a time.
- Re-authorizing an existing email updates that account's tokens instead of creating a duplicate.

### Google Cloud setup

Follow [gmail-setup.md](gmail-setup.md):

1. Enable Gmail API in Google Cloud Console.
2. Create a **Desktop app** OAuth client.
3. Add redirect URI: `http://127.0.0.1:8765/`
4. Paste Client ID and Secret in Settings → Mail → Gmail OAuth App.
5. Click **Add Gmail Account** and complete sign-in.

## IMAP accounts

### Namecheap Private Email

| Setting | Value |
|---|---|
| IMAP host | `mail.privateemail.com` |
| IMAP port | `993` (SSL) |
| SMTP host | `mail.privateemail.com` |
| Password | Your mailbox password |

In Settings → Mail → **Add IMAP Account**, choose **Namecheap Private Email**, enter email and password.

### iCloud Mail

| Setting | Value |
|---|---|
| IMAP host | `imap.mail.me.com` |
| IMAP port | `993` (SSL) |
| SMTP host | `smtp.mail.me.com` |
| Password | **App-specific password** (not your Apple ID password) |

Generate an app-specific password at [appleid.apple.com](https://appleid.apple.com/account/manage) → Sign-In and Security → App-Specific Passwords.

In Settings → Mail → **Add IMAP Account**, choose **iCloud**, enter your `@icloud.com` / `@me.com` address and the app-specific password.

Per-account IMAP passwords are stored in Keychain as `mail_imap_password_<accountId>`.

## Legacy single-account migration

Upgrading from a single flat `gmail_*` Keychain entry automatically migrates tokens into the first `MailAccount` on launch. Legacy keys are removed once namespaced tokens are confirmed.

## Agent tool (`manage_mail`)

Registered on the **General** agent. Actions:

| Action | Purpose |
|---|---|
| `get_status` | Connected accounts, unread counts, sync health |
| `list_unread` | Index only (metadata + snippets) |
| `search` | Index only search across accounts |
| `read_message` | Full body (required before summarization) |
| `archive_message`, `mark_read` | Mailbox actions |
| `create_draft`, `send_email`, `reply_to_message` | Draft-only send path; user confirms in `MailSendConfirmPanel` |

Every response includes a `=== MAIL FETCH REPORT ===` block. `MailReadAuditor` blocks assistant responses that summarize email without a `read_message` call in the same turn.

iMessage remote sessions: read/search allowed; send/archive denied via `SecurityPolicy.isMailActionPermitted()`.

## Briefing home integration

`BriefingInboxSection` appears between **Yesterday** and **Today** on the home screen:

- One-line AI digest (e.g. *"2 need reply · 5 newsletters · 1 invite"*)
- Up to 8 priority-ranked unread rows with account badges
- **Review N newsletters** CTA when weekly cleanup candidates exist

## Integration layer

| File | Role |
|---|---|
| `zoro/Integrations/Mail/MailAccount.swift` | Account model and IMAP presets |
| `zoro/Integrations/Mail/MailAccountStore.swift` | JSON persistence + Keychain schema |
| `zoro/Integrations/Mail/MailProvider.swift` | Provider protocol and shared mail types |
| `zoro/Integrations/Mail/GmailMailProvider.swift` | Gmail implementation of `MailProvider` |
| `zoro/Integrations/Mail/IMAP/IMAPMailProvider.swift` | IMAP implementation (MailCore2) |
| `zoro/Integrations/Mail/MailSyncActor.swift` | Actor-isolated network I/O |
| `zoro/Integrations/Mail/MailManager.swift` | Unified sync, ranking, session read tracking |
| `zoro/Integrations/Mail/MailTool.swift` | `manage_mail` LLM tool |
| `zoro/Integrations/Mail/MailReadAuditor.swift` | Anti-hallucination response blocking |
| `zoro/Integrations/Gmail/GmailAuthManager.swift` | Multi-account OAuth |
| `zoro/Integrations/Gmail/GmailService.swift` | Gmail REST client (per `accountId`) |
| `zoro/Views/Mail/SettingsMailAccountsSection.swift` | Settings Mail tab UI |

## Build and test

Requires **macOS with Xcode 26+** (project targets macOS 27). Use Xcode-beta if that is your installed SDK:

```bash
# Build
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project zoro.xcodeproj -scheme zoro build

# Run unit tests
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project zoro.xcodeproj -scheme zoro test
```

Or in Xcode: select the `zoro` scheme → **Product → Test** (⌘U).

### Test coverage (mail)

| Test file | Covers |
|---|---|
| `zoroTests/Mail/MailPriorityRankerTests.swift` | Priority ranking, digest counts |
| `zoroTests/Mail/CleanupHeuristicsTests.swift` | Newsletter detection, cleanup candidacy |
| `zoroTests/Mail/EmailCalendarDetectorTests.swift` | `.ics` parsing, calendar proposals |
| `zoroTests/Mail/MailReadAuditorTests.swift` | Anti-hallucination enforcement |
| `zoroTests/Gmail/GmailParsingTests.swift` | Gmail-specific parsing helpers |

### XcodeBuild MCP (Cursor)

When Cursor runs on macOS with XcodeBuildMCP enabled (`.cursor/mcp.json`, `.xcodebuildmcp/config.yaml`):

1. `build_macos` — compile the app
2. `test_macos` — run `zoroTests`
3. `build_run_macos` — build and launch (requires GUI session)

Session defaults use the `zoro` scheme and `./zoro.xcodeproj`.

## Troubleshooting

| Issue | Fix |
|---|---|
| Gmail OAuth fails | Confirm redirect URI `http://127.0.0.1:8765/` in Google Cloud; check Client ID/Secret in Settings → Mail |
| Port 8765 in use | Close other apps using the port; retry **Add Gmail Account** |
| iCloud login fails | Use an app-specific password, not your Apple ID password |
| Namecheap IMAP fails | Verify mailbox password; confirm IMAP is enabled in Namecheap panel |
| Briefing Inbox empty | Settings → Mail → **Sync All**; check per-account sync status |
| Agent blocked summarizing mail | Agent must call `read_message` after `list_unread`/`search` — retry the prompt |
| MailCore2 build error | Ensure Xcode resolved SPM dependency; clean build folder and rebuild |
