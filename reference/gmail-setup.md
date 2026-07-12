# Gmail setup

Zoro uses **Gmail OAuth** as one provider under the unified `manage_mail` tool. IMAP accounts are configured separately in Settings → Mail.

## Google Cloud OAuth

1. Create a Google Cloud project and enable the **Gmail API**.
2. Configure an **OAuth desktop** client.
3. Set the authorized redirect URI to exactly:

   `http://127.0.0.1:8765/`

4. Copy **Client ID** and **Client Secret**.
5. In Zoro → Settings → Mail, paste Client ID and Client Secret (stored in Keychain).
6. Click **Connect Gmail** and complete the browser consent flow.

## Code map

| File | Role |
|------|------|
| `GmailAuthManager.swift` | OAuth + multi-account tokens in Keychain |
| `GmailService.swift` | Gmail REST client used by `GmailMailProvider` |
| `GmailParsing.swift` | MIME / body helpers |
| `GmailMailProvider.swift` | `MailProvider` adapter |
| `MailTool.swift` / `MailManager.swift` | LLM-facing `manage_mail` + briefing |
| `MailReadAuditor.swift` | Blocks unsourced email summaries in chat |

## Behavior notes

- Send path stages a draft → user confirms in the app bar (`PendingActionsBar`).
- Remote iMessage sessions: read/search allowed; send/archive denied in `SecurityPolicy`.
