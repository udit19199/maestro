#!/bin/bash
# Checks the Gmail and Calendar tools without Google credentials, through pi RPC and Relay:
# a mail search fails with a plain "not connected" error, a denied approval blocks gmail_send,
# and message_bot still hands off. Pass a built app's maestro-pi.ts to check the bundled copy.
set -euo pipefail
extension=$(realpath "${1:-$(dirname "$0")/../maestro/Pi/maestro-pi.ts}")
agent=$(mktemp -d /tmp/maestro-google.XXXXXX)
trap 'rm -rf "$agent"' EXIT
# models.json holds no secret: pi reads Relay's key at request time.
cp "$HOME/Library/Application Support/Maestro/pi/agent/models.json" "$agent/"
cd "$agent"
env -i HOME="$HOME" PATH=/opt/homebrew/bin:/usr/bin:/bin PI_CODING_AGENT_DIR="$agent" \
  PI="$HOME/Library/Application Support/Maestro/pi/runtime/node_modules/.bin/pi" EXTENSION="$extension" \
  MAESTRO_BOTS=Helper node --input-type=module -e '
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
const pi = spawn(process.env.PI, ["--mode", "rpc", "--no-session", "--no-mcp", "--model", "relay/claude-haiku-5-5", "-e", process.env.EXTENSION]);
const send = value => pi.stdin.write(JSON.stringify(value) + "\n");
const steps = [
  ["Use gmail_search to find my unread email.", "gmail_search", /Google is not connected\. Put your OAuth client file at .*google-client\.json/],
  ["Use gmail_send to email test@example.com with subject Hi and body Hello.", "gmail_send", /did not approve/],
  ["Use message_bot to tell Helper: hello.", "message_bot", /Sent to Helper/],
];
let step = 0, seen = "", asked = false, handoff = false;
const next = () => step < steps.length ? send({ type: "prompt", message: steps[step][0] + " Do not retry." }) : (pi.kill(), process.exit(0));
setTimeout(() => { console.error("FAIL: timed out on step", step + 1); process.exit(1); }, 180_000);
createInterface({ input: pi.stdout }).on("line", line => {
  const event = JSON.parse(line);
  if (event.type === "extension_ui_request" && event.method === "confirm") {
    asked = true;
    console.log("confirm asked:", JSON.stringify({ title: event.title, message: event.message }));
    send({ type: "extension_ui_response", id: event.id, confirmed: false });
  }
  if (event.type === "extension_ui_request" && event.method === "notify" && event.message.includes("handoff")) handoff = true;
  if (event.type === "tool_execution_end" && event.toolName === steps[step][1]) seen = event.result.content[0].text;
  if (event.type !== "agent_settled") return;
  const [, tool, expected] = steps[step];
  const ok = expected.test(seen) && (tool !== "gmail_send" || asked) && (tool !== "message_bot" || handoff);
  console.log(ok ? "PASS" : "FAIL", tool, "->", seen);
  if (!ok) process.exit(1);
  step++, seen = "";
  next();
});
next();
'
