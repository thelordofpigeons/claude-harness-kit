#!/bin/bash
# session-start.sh: UserPromptSubmit hook, acts on the first prompt of each day.
# TEMPLATE: parameters HARNESS_TASK_FILE (default ~/.claude/current-task),
#           BRAIN_DIR (default ~/brain), HARNESS_LOCK_DIR (default /tmp).
#
# 1. Prints the active task, so a restarted session resumes mid-workflow.
# 2. Counts session checkpoints older than 2h (written by checkpoint-session.sh
#    and archived by session-end.sh); those are crashed or hard-closed sessions.
#    It only tells the model to offer /promote-sessions once, it never runs it.
# The once-a-day lock lives in /tmp (Git Bash or POSIX shell).

DATE=$(date +%Y%m%d)
LOCK_DIR="${HARNESS_LOCK_DIR:-/tmp}"
LOCK="${LOCK_DIR}/harness-session-start-$DATE"
BRAIN_DIR="${BRAIN_DIR:-$HOME/brain}"
TASK_FILE="${HARNESS_TASK_FILE:-$HOME/.claude/current-task}"

if [ ! -f "$LOCK" ]; then
  touch "$LOCK" 2>/dev/null

  # 1. Active task context
  if [ -f "$TASK_FILE" ] && [ -s "$TASK_FILE" ]; then
    TASK_ID=$(tr -d '[:space:]' < "$TASK_FILE")
    echo "SESSION CONTEXT: Resuming active task ${TASK_ID}. Check where you left off in the workflow and continue from the next step."
  else
    echo "SESSION START: No active task registered. If you are starting new work, the workflow gate will guide you. If you have an existing task in progress, ask the user which task to resume and write its id to ${TASK_FILE}."
  fi

  # 2. Orphaned session checkpoints (from crash, hard-close, accidental shutdown)
  CHECKPOINT_DIR="$BRAIN_DIR/session-checkpoints"
  if [ -d "$CHECKPOINT_DIR" ]; then
    ORPHAN_COUNT=$(DIR="$CHECKPOINT_DIR" node -e "
      const fs = require('fs'), path = require('path');
      const dir = process.env.DIR;
      if (!fs.existsSync(dir)) { console.log(0); process.exit(0); }
      const cutoff = Date.now() - 2*3600*1000; // 2h
      let n = 0;
      for (const f of fs.readdirSync(dir)) {
        if (!f.endsWith('.json')) continue;
        const fp = path.join(dir, f);
        try {
          if (!fs.statSync(fp).isFile()) continue;
          const j = JSON.parse(fs.readFileSync(fp, 'utf8'));
          const t = Date.parse(j.last_active);
          if (t && t < cutoff) n++;
        } catch (e) {}
      }
      console.log(n);
    " 2>/dev/null)

    if [ -n "$ORPHAN_COUNT" ] && [ "$ORPHAN_COUNT" -gt 0 ]; then
      echo "ORPHANED SESSIONS: Found ${ORPHAN_COUNT} session checkpoint(s) older than 2h with no graceful close (likely crashes). Tell the user ONCE and offer: \"Run /promote-sessions to extract them into ${BRAIN_DIR}/sessions/ and ${BRAIN_DIR}/insights/.\" Do not auto-promote."
    fi
  fi
fi
exit 0
