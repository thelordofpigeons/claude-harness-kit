#!/bin/bash
# git-commit-reminder.sh: PostToolUse hook on Bash tool calls (optional).
# TEMPLATE: parameter TRACKER_UPDATE_CMD (text naming your tracker update command
#           or slash command, e.g. "/task-update"). Used only in the message.
#
# After a command containing "git commit", reminds the agent to update the task
# tracker. It closes the loop between code and task state.

# node runtime (consolidated across all hooks, python is not a dependency)
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{process.stdout.write((JSON.parse(d).tool_input||{}).command||'')}catch(e){}})" 2>/dev/null)

if echo "$COMMAND" | grep -q "git commit"; then
  echo "Task tracker: you just committed. Update your task (${TRACKER_UPDATE_CMD:-TRACKER_UPDATE_CMD}) with the status or a short comment." >&2
fi
exit 0
