#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_dir=$(mktemp -d /tmp/maestro-bot-chats.XXXXXX)
xcrun swiftc -o "$check_dir/check" \
  maestro/Agents/*.swift maestro/Conversations/*.swift \
  maestro/Pi/*.swift \
  scripts/BotChatsCheck.swift
cp maestro/Pi/maestro-pi.ts "$check_dir/maestro-pi.ts"
# Reuse installed code, but keep credentials and session writes in the isolated home.
mkdir -p "$check_dir/Library/Application Support/Maestro/pi"
ln -s "$HOME/Library/Application Support/Maestro/pi/runtime" \
  "$check_dir/Library/Application Support/Maestro/pi/runtime"
CFFIXED_USER_HOME="$check_dir" "$check_dir/check"
