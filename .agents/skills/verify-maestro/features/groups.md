# Group chats

Two to six bots share one chat. The first member is the lead: it answers when no one is @mentioned.

## Sub-features

- `group-mention`: an @mention picks the member whose whole name matches, so `@Al` never picks a bot called `Alex`.
- `group-members`: a group's members can change after creation, and the chat keeps its history.

## How to get to it (user POV)

- New Chat, toggle two or more bots; the first one you pick leads.
- In a group chat, click the members button in the header to add or remove a bot.
- Type `@Name` to make that member answer instead of the lead.

## Driving it

Preconditions: the doctor passes and `check-bot-chats.sh` is green. Both paths below are covered by that isolated check, so no live message is needed.

- Action: run the isolated check.
  - Command: `bash scripts/check-bot-chats.sh`
  - Result: PASS lines for the Host+Critic group, for `@Al` against `@Alex`, and for changing a group's members.
- Action (live, changes saved data): open a group and change the members in the header.
  - Result: the header lists the new member and `conversations.json` shows it in `extraBotIDs`.
  - Back up `conversations.json` first and record the backup path.

## Gotchas

- A one-bot chat cannot become a group. A one-bot chat keeps the pi session path `sessions/<chat id>`, while a group uses `sessions/<chat id>-<bot id>`, so old history would stop loading. `setMembers` only edits existing groups.
- A group never drops below two members. The picker is disabled, and `setMembers` ignores the change.
- Members cannot change while a bot is answering: the picker is disabled, and the store refuses the write.
- Removing a member leaves its old session folder in place; it is unused, not broken.
