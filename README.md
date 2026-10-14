# Zoro

Native macOS app for custom bots and persistent conversations. Every bot runs through pi RPC. Pi owns inference credentials and MCP authentication.

## Build and run

Requires macOS 27+, Xcode, Node 22.19+, and pi 1.2.0. The current development machine has pi installed in Zoro's application-support directory.

1. Open `zoro.xcodeproj`, select the `zoro` scheme, and build and run.
2. Open Settings in the main Zoro window.
3. Use the configured local CLIAuthProxy, or select a provider from Settings > Providers and use its supported sign-in method.
4. Select a default model from the models pi reports.
5. Create a bot conversation from Home or New Chat.

Setup does not require the user to operate pi or run terminal commands.

## Notion

In Settings > MCP servers, select Connect beside Notion. Zoro calls pi's native `mcp add` and `mcp login` commands. Pi owns server configuration, OAuth, token refresh, discovery, and tool execution. Local agent sessions use enabled servers from `mcp.json`. Imported remote chats retain MCP restrictions. Calls that are not marked read-only require approval in Zoro.

Chat deletion is available in the conversation header and the sidebar context menu. It stops the conversation process and removes the chat from the saved list.

## Credential ownership

Pi's configuration and credentials live in `~/Library/Application Support/Zoro/pi/agent/`. Bot definitions and conversation snapshots contain no secrets. Bot definitions live in `bots/<bot-id>/definition.json`. Chats store only the selected bot ID, not its instructions or model. Loading an old chat moves its embedded definition into the store before saving the chat in the new format. All bot processes share that pi configuration. Child environments include only basic OS environment values and the pi directory, not ambient provider keys.

The local CLIAuthProxy provider uses pi’s `models.json` and reads its client key from the proxy’s existing config at request time. It does not copy the key into Zoro’s credential store. The inference and Notion paths do not access Keychain. Earlier development credential copies are not imported, read, or removed by this runtime.

## Current scope

Existing bot definitions, pi conversations, provider authentication, model selection from pi’s catalog, and native MCP setup. Bot creation and editing are not included. Memory, briefing, mail, calendar, iMessage startup, and automatic login-item registration are removed from the active product flow. The unused native integrations and their tools have been removed. Automatic specialist delegation is a later step.

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
- `Pi`: RPC process transport, running conversation sessions, provider/MCP settings, and `zoro-pi.ts`.
- `Views`: SwiftUI screens.
- `App`: window and application lifecycle.

`zoro-pi.ts` is a pi extension copied into the app bundle by Xcode. Pi loads it to expose its provider catalog and login prompts to the native UI, and to request approval for MCP tool calls. Pi still owns provider authentication and MCP execution.
