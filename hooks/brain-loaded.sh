#!/bin/bash
# brain-loaded.sh: SessionStart hook. Emits one status line as a systemMessage.
# Parameter: BRAIN_DIR (default ~/brain).
#
# Reads structure and counts only, never note content. Reports: last session
# date, open threads in RECENT.md, TELOS files past their review cadence (from
# the stability and last_reviewed frontmatter keys), and unpromoted session
# checkpoints older than 2h. This replaced a status line that reported metrics
# nobody used.

set -u

BRAIN="${BRAIN_DIR:-$HOME/brain}"
SESSIONS="$BRAIN/sessions"
RECENT="$BRAIN/RECENT.md"
TELOS="$BRAIN/telos"
CKPT="$BRAIN/session-checkpoints"

LAST=""
if [ -d "$SESSIONS" ]; then
  latest=$(ls "$SESSIONS" 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}' | sort | tail -1)
  [ -n "$latest" ] && LAST="${latest:0:10}"
fi

THREADS=0
if [ -f "$RECENT" ]; then
  THREADS=$(awk '/^## Open Threads/{f=1;next} /^## /{f=0} f && /^- /{c++} END{print c+0}' "$RECENT")
fi

# TELOS review cadence: stable=90d, changing=30d, volatile=7d (see telos 00-index.md)
OVERDUE=$(TELOS_DIR="$TELOS" node -e "
  const fs=require('fs'),p=require('path');const dir=process.env.TELOS_DIR;
  const days={stable:90,changing:30,volatile:7};const now=Date.now();const out=[];
  if(fs.existsSync(dir)) for(const f of fs.readdirSync(dir)){
    if(!f.endsWith('.md')) continue;
    const t=fs.readFileSync(p.join(dir,f),'utf8').slice(0,600);
    const s=(t.match(/^stability:\s*(\w+)/m)||[])[1];const r=(t.match(/^last_reviewed:\s*(\S+)/m)||[])[1];
    if(!s||!r||!days[s]) continue;
    const age=(now-new Date(r).getTime())/864e5;
    if(age>days[s]) out.push(f.replace(/\.md$/,''));
  }
  process.stdout.write(out.join(','));
" 2>/dev/null || true)

ORPHANS=0
if [ -d "$CKPT" ]; then
  ORPHANS=$(CK="$CKPT" node -e "
    const fs=require('fs'),p=require('path');const d=process.env.CK;let n=0;const cut=Date.now()-2*3600e3;
    for(const f of fs.readdirSync(d)){ if(!f.endsWith('.json')) continue;
      try{const j=JSON.parse(fs.readFileSync(p.join(d,f),'utf8'));const t=new Date(j.last_active||0).getTime(); if(t<cut) n++;}catch(e){} }
    process.stdout.write(String(n));
  " 2>/dev/null || echo 0)
fi

LINE="Brain: last session ${LAST:-none} | ${THREADS} open threads"
[ -n "$OVERDUE" ] && LINE="$LINE | TELOS overdue: ${OVERDUE}"
[ "$ORPHANS" -gt 0 ] 2>/dev/null && LINE="$LINE | ${ORPHANS} unpromoted checkpoints"

LINE_OUT="$LINE" node -e "
  const line = process.env.LINE_OUT;
  const ctx = line + '\\n\\n(The brain-loaded SessionStart hook has already shown this status as a systemMessage. Do NOT print a Brain line yourself. Continue with the session-start steps in your CLAUDE.md.)';
  console.log(JSON.stringify({
    systemMessage: line,
    hookSpecificOutput: { hookEventName: 'SessionStart', additionalContext: ctx }
  }));
"
