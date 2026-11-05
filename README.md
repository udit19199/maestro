# Maestro

Native macOS app for custom bots and persistent conversations. Every bot runs through pi RPC. Pi owns inference credentials and MCP authentication.

## Build and run

Requires macOS 27+, Xcode, Node 22.19+ in `/opt/homebrew/bin`, pi 1.2.0, and Relay running at `127.0.0.1:8317`. Install pi once:

```bash
cd ~/Library/Application\ Support/Maestro/pi/runtime && npm install @earendil-works/pi-coding-agent@1.2.0
```

Pi reaches Relay through the `relay` provider in `pi/agent/models.json`; new bots default to `relay/claude-sonnet-5-5`.

1. Open `maestro.xcodeproj`, select the `maestro` scheme, and build and run.
2. Open Settings in the main Maestro window.
3. Use the configured local Relay, or select a provider from Settings > Providers and use its supported sign-in method.
4. Select a default model from the models pi reports.
5. Create a bot conversation from Home or New Chat.

Setup does not require the user to operate pi or run terminal commands.

## Notion

In Settings > MCP servers, select Connect beside Notion. Maestro calls pi's native `mcp add` and `mcp login` commands. Pi owns server configuration, OAuth, token refresh, discovery, and tool execution. Local agent sessions use enabled servers from `mcp.json`. Imported remote chats retain MCP restrictions. Calls that are not marked read-only require approval in Maestro.

Chat deletion is available in the conversation header and the sidebar context menu. It stops the conversation process and removes the chat from the saved list.

## Credential ownership

Pi's configuration and credentials live in `~/Library/Application Support/Maestro/pi/agent/`. Bot definitions and conversation snapshots contain no secrets. Bot definitions live in `bots/<bot-id>/definition.json`. Chats store only the selected bot ID, not its instructions or model. Loading an old chat moves its embedded definition into the store before saving the chat in the new format. All bot processes share that pi configuration. Child environments include only basic OS environment values and the pi directory, not ambient provider keys.

The local Relay provider uses pi’s `models.json` and reads its client key from `~/.relay/opencode-key` at request time. It does not copy the key into Maestro’s credential store. The inference and Notion paths do not access Keychain. Earlier development credential copies are not imported, read, or removed by this runtime.

## Current scope

Existing bot definitions, pi conversations, provider authentication, model selection from pi’s catalog, native MCP setup, bot hand-offs, group chats, and Gmail and Google Calendar tools. Bot creation and editing are not included. Memory, briefing, iMessage startup, and automatic login-item registration are removed from the active product flow.

## Bot hand-offs

Every bot has a `message_bot` tool and knows the other bots' names. When a bot calls it, Maestro posts "Message from <bot>: …" into the target bot's newest chat (creating one if needed) and wakes that bot, like a DM between bots. A busy bot gets the message when its current reply ends. A chain of hand-offs stops after 4 hops.

Run `bash scripts/check-bot-chats.sh` to check bot selection, persistence, and old-chat migration in an isolated application-support directory. Build and direct app inspection cover the native UI.

## Official references

- [Pi provider authentication](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/providers.md)
- [Pi credential SDK example](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/examples/sdk/09-api-keys-and-oauth.ts)
- [Pi RPC](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc.md)
- [Pi MCP](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/mcp.md)
- [Notion MCP](https://developers.notion.com/guides/mcp/overview)

## Source layout

- `Agents`: bot definitions and the saved bot store.
- `Conversations`: chat records and persistence.
- `Pi`: RPC process transport, running conversation sessions, provider/MCP settings, and `maestro-pi.ts`.
- `Views`: SwiftUI screens.
- `App`: window and application lifecycle.

`maestro-pi.ts` is a pi extension copied into the app bundle by Xcode. Pi loads it to expose its provider catalog and login prompts to the native UI, and to request approval for MCP tool calls. Pi still owns provider authentication and MCP execution.

## Group chats

In New Chat, pick two to six bots to start a group chat. The first bot you pick leads. Pick one bot for a normal chat.

- Write normally and the lead bot answers. Type `@Name` to have that bot answer instead. Mention several bots and they answer one after another, in the order you mentioned them. Only one bot answers at a time.
- Each bot keeps its own pi history for the group. Before a bot answers, Maestro gives it the group messages it has not seen since its last reply.
- When a bot uses `message_bot` to reach another member, the request appears in the group as a line from the sending bot, and the other bot answers there. Hand-offs to bots outside the group still go to that bot's own chat. The 4-hop limit applies to both.
- Older one-bot chats load and keep their history unchanged.

## Gmail and Calendar

Bots read, send, and archive mail in one Gmail account and manage its primary Google Calendar. `maestro-pi.ts` calls the Gmail and Calendar APIs directly. `gmail_search`, `gmail_read`, and `calendar_list` run without asking. `gmail_send`, `gmail_draft`, `gmail_label` (archive, mark read, labels), `calendar_create`, `calendar_update`, and `calendar_delete` wait for your approval in the chat, which shows what will happen. Deny stops the call.

One-time setup in [Google Cloud Console](https://console.cloud.google.com/):

1. Create a project.
2. Enable the Gmail API and the Google Calendar API.
3. Set up the OAuth consent screen as External, in Testing mode, and add your Gmail address as a test user.
4. Create an OAuth client ID of type Desktop app and download its JSON.
5. Save that file as `~/Library/Application Support/Maestro/pi/agent/google-client.json`.

Then open Settings > Google and select Connect. Your browser opens Google sign-in. Maestro asks for `gmail.modify` (read, send, labels) and `calendar.events`, and saves the refresh token in `pi/agent/google-token.json` with owner-only permissions. Google expires refresh tokens for apps in Testing mode after 7 days; select Connect again when a bot reports that sign-in failed.

Run `bash scripts/check-google.sh` to check the tools without a Google account: an unconnected search fails with a clear message, a denied `gmail_send` is blocked, and `message_bot` still works.
