#!/bin/bash
# checkpoint-session.sh: Stop hook.
# Parameters: BRAIN_DIR (default ~/brain), HARNESS_TASK_FILE (default
#             ~/.claude/current-task; optional, the task id is null when absent).
#
# Fires after every assistant response. Writes a tiny JSON checkpoint for this
# session to $BRAIN_DIR/session-checkpoints/<session-id>.json so a hard-close
# (computer crash, accidental shutdown, force-kill) leaves a recoverable
# breadcrumb on disk. /promote-sessions is the example consumer: it reads these
# to extract proper session and insight notes.
#
# Checkpoint shape: {session_id, transcript_path, cwd, task_id, last_active}
# No LLM calls. Cheap (about 10-30ms per turn).

set -u

BRAIN_DIR="${BRAIN_DIR:-$HOME/brain}"
CHECKPOINT_DIR="$BRAIN_DIR/session-checkpoints"
TASK_FILE="${HARNESS_TASK_FILE:-$HOME/.claude/current-task}"
mkdir -p "$CHECKPOINT_DIR" 2>/dev/null

INPUT=$(cat)
TASK_ID=""
[ -f "$TASK_FILE" ] && TASK_ID=$(tr -d '[:space:]' < "$TASK_FILE")

echo "$INPUT" | TASK_ID="$TASK_ID" CHECKPOINT_DIR="$CHECKPOINT_DIR" node -e "
const fs = require('fs');
const path = require('path');
let d = '';
process.stdin.on('data', c => d += c);
process.stdin.on('end', () => {
  try {
    const j = JSON.parse(d);
    const sid = j.session_id;
    if (!sid) process.exit(0);
    const out = {
      session_id: sid,
      transcript_path: j.transcript_path || null,
      cwd: j.cwd || null,
      task_id: process.env.TASK_ID || null,
      last_active: new Date().toISOString(),
    };
    fs.writeFileSync(
      path.join(process.env.CHECKPOINT_DIR, sid + '.json'),
      JSON.stringify(out, null, 2)
    );
  } catch (e) { /* never crash the hook */ }
});
" 2>/dev/null

exit 0
