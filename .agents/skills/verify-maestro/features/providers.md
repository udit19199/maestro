# Providers and models

Settings catalog and model pick through pi.

## Sub-features

- `catalog`: providers list loads from pi.
- `model-pick`: default model selects and sticks.

## How to get to it (user POV)

- Open Settings in the main window.
- Providers shows pi-supported providers. Pick one, sign in with its method.
- Pick the default model from the pi catalog.

## Driving it

Preconditions: live app open, read-only walkthrough allowed.

- Action: open Settings, screenshot Providers and the model picker.
  - Result: catalog entries visible, current default named.
- Action (only if approved): change the default model, restart the app, reopen Settings.
  - Result: the same default still selected.

## Gotchas

- Pi owns auth and MCP (`mcp add`, `mcp login`). Maestro never copies keys.
- CLIAuthProxy reads its key at request time. No keychain involved.
- Imported remote chats keep MCP restrictions. Calls not marked read-only need approval.
