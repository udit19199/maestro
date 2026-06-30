# Zoro Codebase Resources

## Knowledge

- [The Swift Programming Language: A Swift Tour](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/guidedtour/)
  The official beginner-friendly tour of Swift syntax. Use for: Basic types, control flows, structs, and optionals.
- [100 Days of SwiftUI (Hacking with Swift)](https://www.hackingwithswift.com/100/swiftui)
  Highly regarded, free course teaching Swift and SwiftUI from absolute scratch. Use for: Building basic mental models of SwiftUI.
- [Apple Documentation: SwiftUI](https://developer.apple.com/documentation/swiftui)
  Core UI framework documentation. Use for: View layout, `@Published` / `@StateObject` property wrappers, and view updates.
- [Apple Documentation: EventKit](https://developer.apple.com/documentation/eventkit)
  Native calendar and reminders API. Use for: Understanding calendar access permissions and managing events/reminders.
- [AppleScript Language Guide](https://developer.apple.com/library/archive/documentation/AppleScript/Conceptual/AppleScriptLangGuide/)
  Use for: Extending or debugging the native Apple Notes scripting (`osascript`) calls.
- [Swift Concurrency (async/await)](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/)
  Official Swift guide. Use for: Understanding tasks, check continuations, `@MainActor`, and asynchronous streams.
- [Gmail API Overview](https://developers.google.com/gmail/api/guides)
  Official Gmail REST API docs. Use for: messages.list, messages.get, threads.get, OAuth scopes, pagination.
- [Google OAuth 2.0 for Desktop Apps](https://developers.google.com/identity/protocols/oauth2/native-app)
  Use for: Setting up Desktop OAuth credentials and redirect URI (`http://127.0.0.1:8765/` for Zoro).
- [Gmail API Push Notifications](https://developers.google.com/gmail/api/guides/push)
  Optional reading. Use for: Understanding why Zoro uses on-demand fetch instead of webhooks (no public server).
- [Zoro Gmail Setup Guide](../reference/gmail-setup.md)
  Project-specific: Google Cloud setup, Connect Gmail flow, troubleshooting, architecture map.

## Wisdom (Communities)

- [r/swift](https://reddit.com/r/swift)
  Good community for Swift language questions and best practices.
- [Swift Forums](https://forums.swift.org/)
  High-signal discussions about Swift Evolution, concurrency, and platform APIs.
