#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_dir=$(mktemp -d /tmp/zoro-bot-chats.XXXXXX)
xcrun swiftc -o "$check_dir/check" \
  zoro/Agents/*.swift zoro/Conversations/*.swift \
  zoro/Pi/*.swift \
  scripts/BotChatsCheck.swift
cp zoro/Pi/zoro-pi.ts "$check_dir/zoro-pi.ts"
# Reuse installed code, but keep credentials and session writes in the isolated home.
mkdir -p "$check_dir/Library/Application Support/Zoro/pi"
ln -s "$HOME/Library/Application Support/Zoro/pi/runtime" \
  "$check_dir/Library/Application Support/Zoro/pi/runtime"
CFFIXED_USER_HOME="$check_dir" "$check_dir/check"
