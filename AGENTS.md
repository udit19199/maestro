# maestro

Native macOS SwiftUI app. Each chat runs its bots in a pi 1.2.0 RPC process; Swift only routes messages and shows them. The model is Relay (127.0.0.1:8317, a separate repo) through pi's `relay` provider.

- Bot tools (hand-offs, Gmail over IMAP/SMTP, calendar requests) live in `maestro/Pi/maestro-pi.ts`. Calendar requests come back to Swift as a pi `input` request and run on EventKit in `MacCalendar.swift`.
- Anything that sends, drafts, labels or changes the calendar asks the user to approve first. Keep it that way.
- Prove changes with the `verify-maestro` skill in `.agents/skills/`.

Global coding rules apply (see home directory AGENTS.md).
