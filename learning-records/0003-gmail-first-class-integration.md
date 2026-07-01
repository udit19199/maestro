# Gmail First-Class Integration

Added Gmail as a first-class Zoro integration on branch `cursor/gmail-integration-bcf6` (PR #3).

## User context

The user relies heavily on Gmail and wants reliable, complete fetches with minimal hallucination risk.

## What was built

- OAuth 2.0 desktop flow (`GmailAuthManager`) with Keychain token storage
- Gmail REST client (`GmailService`) with pagination, retries, structured fetch reports
- State layer (`GmailManager`) for inbox preview, unread count, activity log, and dynamic agent instructions
- `manage_gmail` tool: get_status, list/search, read_message, read_messages, read_thread, read_attachment, mark_read, send_email, trash_message
- UI (designed, not yet wired): header badge, inbox preview panel, Gmail activity log in chat views
- Security: iMessage remote sessions restricted to read-only Gmail actions

## Wiring status (as of docs sync)

Backend code merged; agent and UI wiring pending:
- `GmailTool` not registered in `AgentRunner.tools(for:)`
- No Gmail section in `SettingsView.swift`
- `GmailReadAuditor` response blocking not wired in `ChatView` / `IMessageListener`

## Key design decision

Separate **index** operations (search/list with snippets) from **read** operations (full bodies). Agent instructions forbid summarizing from snippets alone.

## Pending verification

User will verify OAuth flow and agent behavior on macOS locally.
