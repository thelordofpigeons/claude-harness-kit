#!/bin/bash
# filter-noisy-bash.sh: PreToolUse hook on Bash tool calls.
# Optional parameter: EXTRA_NOISY_RE (extended regex, e.g. 'myplatform (deploy|logs)')
# appended to the built-in list of noisy commands.
#
# Detects build/test/deploy commands likely to flood the context window and
# warns the model to add a head/tail/grep filter. Does NOT block or rewrite;
# the warning goes to stderr where the model can see it and add a filter on
# retry. The filtering convention itself belongs in your CLAUDE.md.

INPUT=$(cat)

# Extract the bash command via Node (jq isn't always installed on Windows).
CMD=$(echo "$INPUT" | node -e "
let d='';
process.stdin.on('data',c=>d+=c);
process.stdin.on('end',()=>{
  try { const j=JSON.parse(d); console.log((j.tool_input||{}).command||''); }
  catch(e) { console.log(''); }
});
" 2>/dev/null)

[ -z "$CMD" ] && exit 0

# Skip if the command already has a head/tail/grep filter
if echo "$CMD" | grep -qE '\|\s*(head|tail|grep|awk|sed|wc)\b'; then
  exit 0
fi

# Patterns that typically produce >100 lines of output
NOISY_RE='\b(npm (run )?build|npm test|tsc(\s|$)|next build|jest|vitest|pytest|docker (build|logs)|yarn (build|test)|pnpm (build|test)|gradle build|mvn (compile|test|package))\b'
[ -n "${EXTRA_NOISY_RE:-}" ] && NOISY_RE="${NOISY_RE}|(${EXTRA_NOISY_RE})"

if echo "$CMD" | grep -qE "$NOISY_RE"; then
  cat >&2 <<EOF
NOISY-COMMAND HOOK: this command typically dumps 5K-50K lines into context.
Recommend re-running with a filter (see the "Noisy command output" section of your CLAUDE.md):
  - build/typecheck:  ... 2>&1 | grep -E '(error|warning|Error|Failed)' | head -100
  - tests:            ... 2>&1 | grep -A 5 -E '(FAIL|PASS|ERROR)' | head -100
  - deploys/logs:     ... 2>&1 | tail -80
Tee to /tmp/<cmd>.log if you might need the full output.
The command will run as-is; this is a nudge, not a block.
EOF
fi

exit 0
