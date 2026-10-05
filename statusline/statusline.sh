#!/bin/bash
# statusline.sh: Claude Code status line wrapper.
# Thin wrapper that delegates to statusline.mjs for UTF-8-safe output.
# Install: copy this file and statusline.mjs to ~/.claude/ and set statusLine in
# settings (see settings.example.json).

INPUT=$(cat)

# Convert Unix path to Windows path for node on Windows (Git Bash)
MJS_PATH="$HOME/.claude/statusline.mjs"
if command -v cygpath &>/dev/null; then
  MJS_WIN=$(cygpath -w "$MJS_PATH")
else
  MJS_WIN="$MJS_PATH"
fi

echo "$INPUT" | node "$MJS_WIN" 2>/dev/null || echo -e "\033[33mstatusline error\033[0m"
