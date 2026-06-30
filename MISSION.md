# Mission: Zoro Codebase Mastery

## Why
Enable the user to confidently maintain, extend, and debug the Zoro macOS application, allowing them to customize the assistant's tools, UI, and AI backend configuration for their personal workflows.

## Success looks like
- Explain the lifecycle of a user prompt, from submission in `ContentView` to stream completion.
- Identify how `WorkspaceManager` acts as the single source of truth and manages background commands and tasks.
- Create and register a new tool conforming to the `Tool` protocol.
- Debug AppleScript, EventKit, Keychain, or Gmail OAuth/API integrations within the existing codebase.
- Connect Gmail, explain the index-vs-read fetch model, and extend `manage_gmail` safely.

## Constraints
- Lessons should be short, modular, and highly practical.
- **No prior Swift or SwiftUI knowledge.** All language features (e.g., Optionals, property wrappers like `@Published`, structs vs classes, closures, and concurrency) must be taught from the ground up as they relate to Zoro's code.

## Out of scope
- Designing custom macOS UI components from scratch (unless modifying the chat UI).
- In-depth AppKit/Cocoa development outside of `NSOpenPanel` or current features.
