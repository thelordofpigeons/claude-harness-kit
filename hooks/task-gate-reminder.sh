#!/bin/bash
# task-gate-reminder.sh: PreToolUse hook, matcher Edit|Write.
# TEMPLATE: parameters TRACKER_AGENT (name of the agent that owns the issue
#           tracker, default "tracker"), HARNESS_TASK_FILE (default
#           ~/.claude/current-task), HARNESS_LOCK_DIR (default /tmp).
#
# Second enforcement point behind workflow-gate.sh. If no task id is registered,
# it emits a reminder to claim a task before editing. A lock file keeps it to one
# reminder per working directory per day so it does not nag.
# The lock uses /tmp, which assumes Git Bash on Windows or a POSIX shell.

TRACKER_AGENT="${TRACKER_AGENT:-tracker}"
TASK_FILE="${HARNESS_TASK_FILE:-$HOME/.claude/current-task}"
LOCK_DIR="${HARNESS_LOCK_DIR:-/tmp}"

if [ ! -f "$TASK_FILE" ] || [ ! -s "$TASK_FILE" ]; then
  DIR_HASH=$(echo "$PWD" | cksum | cut -d' ' -f1)
  DATE=$(date +%Y%m%d)
  LOCK_FILE="${LOCK_DIR}/harness-task-gate-${DIR_HASH}-${DATE}"

  if [ ! -f "$LOCK_FILE" ]; then
    touch "$LOCK_FILE" 2>/dev/null
    echo "WORKFLOW ENFORCEMENT: You are about to edit a file but the task file (${TASK_FILE}) is empty."
    echo "Follow the workflow gate before writing code:"
    echo "  1. Classify the request type"
    echo "  2. Delegate to the ${TRACKER_AGENT} agent to create or claim the task"
    echo "  3. Register it: bash ~/.claude/scripts/task-state.sh init <TASK_ID> \"<TASK_NAME>\""
    echo "Then proceed with implementation."
  fi
fi
exit 0
