# Teaching Notes

## User Preferences
- Learning about the entire Zoro codebase.
- No assumptions on advanced Swift experience; explain key concepts inline.
- Uses Gmail extensively — Gmail integration should be treated as first-class (complete fetches, anti-hallucination guardrails).

## Lesson Tracking
- [x] Lesson 1: Introduction to Swift & SwiftUI (A Beginner's Lens)
- [x] Lesson 2: Zoro Architecture & Lifecycle of a User Request (`AppShell`, `AgentRunner`, `ConversationStore`)
- [ ] Lesson 3: Runtime State & Background Work (`WorkspaceManager` — todos, processes, clarify continuations)
- [ ] Lesson 4: The `Tool` Protocol & AppleScript/EventKit Bridges (Custom Tools)
- [ ] Lesson 5: Creating and Registering a New Tool in `AgentRunner.tools(for:)` (Interactive Coding)
- [ ] Lesson 6: Gmail Integration — OAuth, Fetch Reports, and Anti-Hallucination Design (backend + wiring gaps)
