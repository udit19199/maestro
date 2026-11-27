# Security

## 1. What we protect

| Asset | Worst case |
|---|---|
| The user's mail, calendar, messages | Read by someone else, or sent from the user's account |
| Tokens and API keys | Stolen and used elsewhere |
| Bot files and memory | Changed by injected text so a bot keeps doing harm later |
| The Mac | A bot command deletes files or installs something |

## 2. Trust boundaries

```
 untrusted content ─────────────┐   (mail bodies, web pages, MCP results, channel messages from others)
                                ▼
 model ── tool calls ──► Action gate (typed effect table, policy, never-list) ──► connectors
   ▲                                                         │
   └── context blocks built by the core (audience-filtered) ◄┘
 shell ◄─ stdio pipe ─► core           Keychain, EventKit, Messages only via the shell
```

- **The model is untrusted.** Every effect passes the gate. Policy is code, not prompt.
- **The pipe is the only door to the core.** No port, no socket, so no other local program can drive it. (Some platforms expose a loopback HTTP API that any local process can call; Maestro does not.)
- **The shell trusts the core's output**; they ship together.
- **Files in the workspace are trusted as the user's**, but bots cannot write them (§4).

## 3. Prompt injection

The design does not depend on the model resisting injection. What stops harm:

1. Outward and destructive effects in unattended runs always need the user (permissions.md §8). An injected email in a routine can at most make a draft or a label.
2. Proposals show `from_untrusted_content` and `new_recipient` warnings.
3. Text from bots, hand-offs, routines and channels is labelled with its source in the session (`[Hand-off from Mail]`, `[iMessage from +91…]`). Text inside content that imitates a label is escaped.
4. Memory and ledger blocks are audience-filtered by the core (context.md §6), so injected text in a shared chat cannot pull private memory.
5. Memory writes strip secret-looking strings, and the user can see and undo every memory change.

## 4. Bots cannot change themselves

- Bot files, skills, routines, `mcp.json` and `AGENTS.md` are outside every bot's `workDir` and on the never-list for file and shell tools (permissions.md §7). A bot cannot rewrite its own instructions, give itself tools, or schedule itself.
- The only lasting thing a bot can write is memory, which is capped, journaled and shown.

## 5. Shell access

`bash` is off unless the bot file turns it on. When on, it runs as the user with no sandbox. The never-list blocks obvious destruction by command text, which is easy to get around on purpose. A bot with `shell: true` should be treated as having the user's account. Settings says this in one line when the user turns it on. A sandbox (`sandbox-exec` profile per bot) is a later option.

## 6. Secrets

- In Keychain only (connectors.md §6). In memory in the core while it runs. Never in SQLite, logs, events or prompts.
- Logs redact anything matching token patterns before writing.
- The Google client secret shipped in the app is not a secret by Google's own definition (connectors.md §2.2); it is in the source.

## 7. Data leaving the Mac

Only to: the model provider the user chose, Google (Gmail API, OAuth), Apple (iMessage), and MCP servers the user added. No telemetry, no crash upload, no update check except the one the user turns on.
</content>
