#!/bin/bash
# session-end.sh: SessionEnd hook.
# Parameter: BRAIN_DIR (default ~/brain).
#
# When a session ends, check whether the session epilogue was actually written
# (any $BRAIN_DIR/sessions/*.md modified in the last 60 minutes). If yes, archive
# this session's checkpoint to session-checkpoints/processed/ so it is never
# flagged as an orphan. If no epilogue was written, leave the checkpoint in
# place and /promote-sessions can recover it later. Only unfinished sessions
# therefore show up as orphans.
#
# No LLM calls. Node-only runtime (same as the other hooks).

set -u

BRAIN_DIR="${BRAIN_DIR:-$HOME/brain}"
export BRAIN_DIR

INPUT=$(cat)

echo "$INPUT" | node -e "
const fs = require('fs');
const path = require('path');
let d = '';
process.stdin.on('data', c => d += c);
process.stdin.on('end', () => {
  try {
    const j = JSON.parse(d);
    const sid = j.session_id;
    if (!sid) process.exit(0);

    const brain = process.env.BRAIN_DIR;
    const cpDir = path.join(brain, 'session-checkpoints');
    const cpFile = path.join(cpDir, sid + '.json');
    if (!fs.existsSync(cpFile)) process.exit(0);

    // Was a session epilogue written recently?
    const sessionsDir = path.join(brain, 'sessions');
    const cutoff = Date.now() - 60 * 60 * 1000;
    let epilogueWritten = false;
    if (fs.existsSync(sessionsDir)) {
      for (const f of fs.readdirSync(sessionsDir)) {
        if (!f.endsWith('.md')) continue;
        const st = fs.statSync(path.join(sessionsDir, f));
        if (st.mtimeMs >= cutoff) { epilogueWritten = true; break; }
      }
    }
    if (!epilogueWritten) process.exit(0);

    const processedDir = path.join(cpDir, 'processed');
    fs.mkdirSync(processedDir, { recursive: true });
    fs.renameSync(cpFile, path.join(processedDir, sid + '.json'));
  } catch (e) { /* never crash the hook */ }
});
" 2>/dev/null

exit 0
