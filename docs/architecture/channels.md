# Channels

A **channel** is a way to reach bots from outside the app. v1 has two: the desktop app itself, and iMessage. The Router treats both the same: a channel message is an input to a thread (runtime.md §1).

## 1. The desktop

The shell's composer. Every thread is a desktop thread. Nothing more to say.

## 2. iMessage: the problem

iMessage is one endless conversation. If it were one thread with one episode, the context would grow forever and mix every subject. If every message were a new thread, nothing would carry over. Bots also reach the user through iMessage from other threads ("P-12 needs you", a routine's morning brief), and the user's answer must land back in the thread that asked.

## 3. Setup

- macOS allows one iMessage account in Messages. So v1 uses the user's own account and a **self-chat**: the user messages their own number or address. Maestro watches that one chat (open question Q2; the other option, a second Apple ID for the bot, takes over the Mac's Messages).
- Maestro's replies in the self-chat start with the bot's name ("Mail: …"), because Messages marks both sides as "from me".
- Permissions: **Full Disk Access** for `Maestro.app`, to read `~/Library/Messages/chat.db`, and **Automation** of Messages, to send (assumption A4: the core, as the app's child, is covered by the app's grants).
- Binding other chats (a group with friends) is not in v1. The model supports it: such a binding has audience `shared` and its sender handles become `person` authors.

## 4. Episode rules

The self-chat is one `channel` thread, bound to a default bot (Settings), with `@name` for others.

1. **The user replies to a specific message** (iMessage's reply): the core looks up the replied-to message's guid in `channel_messages`, finds the Maestro message, and sends the reply to **that message's thread**. If that thread's episode is closed, a new one opens with carry-over. So answering "P-12 needs you" from the phone lands in the thread that proposed P-12.
2. **A plain message within the gap** (default 2 hours since the channel thread's last message, open question Q3): it continues the open episode.
3. **A plain message after the gap, or the text `new`:** the open episode closes (carry-over written), and a new episode starts.
4. **`/<bot>` or `@bot` at the start** picks the bot for that message; otherwise the default bot.

A small model that guesses which open thread a plain message belongs to is left out of v1. The reply gesture covers the case where it matters.

## 5. Inbound

- The watcher reads `chat.db` read-only (SQLite, `?mode=ro`) every 2 s, from the last `message.ROWID` it saw (`channel_cursors`). It uses the file's change time to skip reads when nothing changed.
- It takes rows in the bound chat that Maestro did not send (their guid is not in `channel_messages` as `out`). Text is `message.text`, or decoded from `attributedBody` when `text` is empty (newer macOS stores it there).
- The reply link is `message.thread_originator_guid` (assumption A5).
- Each inbound row becomes a `messages` row (author `user`, or `person` for a shared binding) and a `channel_messages` row, in one transaction, then a run request.
- A message whose guid is already in `channel_messages` is skipped, so a restart never doubles one.

## 6. Outbound

- A bot's reply in a channel thread is sent with host request `messages.send` (AppleScript to Messages, run by the shell). The shell returns the new message's guid when it can read it back from `chat.db`; the core stores it in `channel_messages` as `out`.
- Other threads reach the user through iMessage only through `notify_user` (a `local` tool, sent to the self-chat): proposals waiting longer than 15 minutes while the Mac is idle, routine briefs that ask for it, and `needs_user` flags due today. Each such message records its own thread, so rule 1 brings the reply back.
- Long replies are cut at 1,500 characters with "(more in Maestro)".
- iMessage to anyone other than the owner is `messages_send`, effect `outward`, so it asks (permissions.md).

## 7. Failure

- No Full Disk Access: the channel shows "Needs Full Disk Access" with a button to the System Settings pane. Nothing else breaks.
- Messages not signed in, or the send fails: the reply stays in the Maestro thread, marked "Not delivered to iMessage", with Retry.
</content>
