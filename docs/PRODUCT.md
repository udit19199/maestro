# Product

Maestro is an open-source Mac app where named bots do one person's work. Each user runs their own copy; there is no Maestro server or account.

- **Bots are files.** Each bot is `.agents/agents/<bot>.md` in the user's workspace, with skills in `.agents/skills/`. Other agent tools can read the same files.
- **Threads stay separate.** A bot in three chats runs as three separate contexts. It keeps track of its open work and lasting facts across all of them, so nothing is forgotten and nothing leaks between chats.
- **Groups and hand-offs.** A chat can hold several bots; bots pass work to each other.
- **Routines.** Bots run on a schedule or when mail arrives, with the window closed.
- **Reach it from iMessage.** Replies to a bot's message go back to the chat that sent it.
- **Mail and calendar first.** Gmail through Google sign-in in one click (or an app password), and the Mac's calendars.
- **Low friction, safe sends.** Bots read, label, draft and organise without asking. Anything other people would see, and anything permanent, waits for the user's yes, without blocking the bot.
- **Any model.** Any pi provider; Relay is one option.

Design: `docs/architecture/` (system) and `docs/DESIGN.md` (screens).
