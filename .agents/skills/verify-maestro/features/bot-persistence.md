# Bot persistence check

Isolated logic proof. No app launch, no real data touched.

## Sub-features

- `selection`: bot store loads and selects.
- `migration`: old embedded chat definitions move into the store.
- `live-catalog`: pi answers `/maestro-providers` and a stop round trip.

## How to get to it (user POV)

- Bots stay selected between messages and restarts.
- Old chats keep working after the format change.

## Driving it

Preconditions: none beyond a checkout. Temp home is built in.

- Action: run the isolated check.
  - Command: `mkdir -p /tmp/verify-maestro; VERIFY_DIR="$(mktemp -d /tmp/verify-maestro/XXXXXX)"; bash scripts/check-bot-chats.sh 2>&1 | tee "$VERIFY_DIR/check.log"; echo "$VERIFY_DIR"`
  - Result: stdout shows `PASS:` lines through the live pi step. If pi runtime is missing the script traps; stop as blocked, do not proceed to the app.
- Action: keep the evidence.
  - Command: `VERIFY_DIR="$(mktemp -d /tmp/verify-maestro/XXXXXX)"; bash scripts/check-bot-chats.sh 2>&1 | tee "$VERIFY_DIR/check.log"; echo "$VERIFY_DIR"`
  - Result: `check.log` kept under its run dir.

## Gotchas

- The script symlinks only the pi `runtime` dir and writes the rest to temp. Real `conversations.json` is never read.
- A failure in the live pi step means pi or its runtime is broken, not the chat UI. Fix pi first.
- This proves logic, not pixels. Pair with `new-chat` for app proof.
