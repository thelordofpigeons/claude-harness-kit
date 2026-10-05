#!/usr/bin/env bash
# selftest.sh: verifies the hooks, scripts and settings example in this kit.
# TEMPLATE: the pre-deploy-validate check below uses the default deploy command of
#           that template hook (the public clever-tools CLI) as its fixture.
#
#   bash scripts/selftest.sh
#
# What it does:
#   1. Syntax checks: bash -n on every .sh, node --check on every .mjs, workflow
#      scripts parsed as async function bodies, PowerShell files parsed when
#      powershell.exe is available, settings.example.json parsed as JSON and
#      every hook command it names must exist in this kit.
#   2. design-lint: must exit non-zero on fixtures/bad.* and zero on fixtures/good.*,
#      and must flag a dash character that is generated at run time (so the
#      fixture files themselves hold no dash).
#   3. Each hook runs with fabricated stdin JSON inside a temporary HOME and
#      BRAIN_DIR. Nothing under your real home or real brain is read or written.
#
# Prints PASS or FAIL per check and exits 1 if any check failed. Needs bash,
# node and git. The dev-server-reaper check only does real work on Windows.

set -u

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_HOME="$HOME"

# Native Windows node needs C:/ style paths; Git Bash accepts them too.
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

T="$(winpath "$(mktemp -d)")"
trap 'rm -rf "$T"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s  (%s)\n' "$1" "${2:-}"; }
contains() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

# expect NAME CONDITION_RESULT(0=true) [DETAIL]
expect() { if [ "$2" -eq 0 ]; then pass "$1"; else fail "$1" "${3:-}"; fi; }

# run_hook STDIN CMD...   sets OUT, ERR, RC
run_hook() {
  local input="$1"; shift
  OUT="$(printf '%s' "$input" | "$@" 2>"$T/err")"
  RC=$?
  ERR="$(cat "$T/err")"
}

# ---------------------------------------------------------------------------
# Sandbox: fake home and brain. Everything below uses these.
# ---------------------------------------------------------------------------
export HOME="$T/userhome"
export USERPROFILE="$T/userhome"
export BRAIN_DIR="$T/brain"
export HARNESS_TASK_FILE="$T/userhome/.claude/current-task"
export HARNESS_LOCK_DIR="$T/locks"
export CLAUDE_HOME="$T/userhome/.claude"
export DESIGN_LINT="$KIT/scripts/design-lint.mjs"
mkdir -p "$HOME/.claude" "$BRAIN_DIR" "$HARNESS_LOCK_DIR"

echo "== syntax =="
for f in "$KIT"/hooks/*.sh "$KIT"/scripts/*.sh "$KIT"/statusline/*.sh; do
  bash -n "$f" 2>"$T/err"; expect "bash -n ${f#$KIT/}" $? "$(cat "$T/err")"
done
for f in "$KIT"/hooks/*.mjs "$KIT"/scripts/*.mjs "$KIT"/statusline/*.mjs; do
  node --check "$f" 2>"$T/err"; expect "node --check ${f#$KIT/}" $? "$(head -c 200 "$T/err")"
done
for f in "$KIT"/workflows/*.js; do
  node -e "
    const fs = require('fs');
    const src = fs.readFileSync(process.argv[1], 'utf8').replace(/^export const meta/m, 'const meta');
    const AF = Object.getPrototypeOf(async function () {}).constructor;
    new AF('args', 'agent', 'parallel', 'phase', 'log', 'budget', src);
  " "$f" 2>"$T/err"
  expect "workflow parses ${f#$KIT/}" $? "$(head -c 200 "$T/err")"
done
if command -v powershell.exe >/dev/null 2>&1; then
  for f in "$KIT"/scripts/*.ps1; do
    MSYS_NO_PATHCONV=1 powershell.exe -NoProfile -NonInteractive -Command "\$e=\$null; [void][System.Management.Automation.Language.Parser]::ParseFile('$(winpath "$f")',[ref]\$null,[ref]\$e); if (\$e.Count) { exit 1 }" >/dev/null 2>&1
    expect "powershell parse ${f#$KIT/}" $?
  done
else
  echo "SKIP  powershell parse (powershell.exe not found)"
fi
node -e "
  const fs = require('fs'), path = require('path');
  const kit = process.argv[1];
  const s = JSON.parse(fs.readFileSync(path.join(kit, 'settings.example.json'), 'utf8'));
  const cmds = [];
  for (const groups of Object.values(s.hooks)) for (const g of groups) for (const h of g.hooks) cmds.push(h.command);
  cmds.push(s.statusLine.command);
  let missing = [];
  for (const c of cmds) {
    const m = c.match(/~\/\.claude\/(\S+)/);
    if (!m) { missing.push('unparsed: ' + c); continue; }
    const rel = m[1].replace(/\"/g, '');
    const cand = rel.startsWith('statusline.') ? path.join(kit, 'statusline', rel) : path.join(kit, rel);
    if (!fs.existsSync(cand)) missing.push(rel);
  }
  if (!s.permissions || s.permissions.allow.length || s.permissions.deny.length) missing.push('permissions must be empty');
  if (missing.length) { console.error(missing.join(', ')); process.exit(1); }
" "$KIT" 2>"$T/err"
expect "settings.example.json: valid, every command exists, permissions empty" $? "$(cat "$T/err")"

echo "== design-lint =="
for f in bad.css bad.tsx; do
  node "$KIT/scripts/design-lint.mjs" "$KIT/scripts/fixtures/$f" >/dev/null 2>&1; rc=$?
  expect "design-lint fails on fixtures/$f" $([ "$rc" -eq 1 ] && echo 0 || echo 1) "rc=$rc"
done
for f in good.css good.tsx; do
  node "$KIT/scripts/design-lint.mjs" "$KIT/scripts/fixtures/$f" >/dev/null 2>&1; rc=$?
  expect "design-lint passes fixtures/$f" $([ "$rc" -eq 0 ] && echo 0 || echo 1) "rc=$rc"
done
# A dash character built at run time (the fixtures stay free of it).
printf '<p>one \342\200\224 two</p>\n' > "$T/dash.html"
OUT="$(node "$KIT/scripts/design-lint.mjs" "$T/dash.html" 2>&1)"; rc=$?
expect "design-lint flags a literal em dash in markup" $([ "$rc" -eq 1 ] && contains "$OUT" "em-dash" && echo 0 || echo 1) "rc=$rc"
printf '<p>one %s%s two</p>\n' '\' 'u2014' > "$T/dash2.html"
OUT="$(node "$KIT/scripts/design-lint.mjs" "$T/dash2.html" 2>&1)"; rc=$?
expect "design-lint flags an escaped em dash in markup" $([ "$rc" -eq 1 ] && contains "$OUT" "em-dash" && echo 0 || echo 1) "rc=$rc"

echo "== hooks =="
# workflow-gate
run_hook '{"prompt":"build a new component for the dashboard"}' bash "$KIT/hooks/workflow-gate.sh"
expect "workflow-gate: code request without task prints the gate" $([ "$RC" -eq 0 ] && contains "$OUT" "WORKFLOW GATE" && contains "$OUT" '`workflow`' && echo 0 || echo 1) "$OUT"
WORKFLOW_SKILL=my-skill run_hook '{"prompt":"implement an endpoint for orders"}' bash "$KIT/hooks/workflow-gate.sh"
expect "workflow-gate: WORKFLOW_SKILL is honored" $(contains "$OUT" "my-skill" && echo 0 || echo 1) "$OUT"
run_hook '{"prompt":"how can I build a component for this"}' bash "$KIT/hooks/workflow-gate.sh"
expect "workflow-gate: questions are skipped" $([ -z "$OUT" ] && echo 0 || echo 1) "$OUT"
printf 'TASK-1' > "$HARNESS_TASK_FILE"
run_hook '{"prompt":"fix the bug in the parser module"}' bash "$KIT/hooks/workflow-gate.sh"
expect "workflow-gate: active task prints resume context" $(contains "$OUT" "WORKFLOW CONTEXT" && contains "$OUT" "TASK-1" && echo 0 || echo 1) "$OUT"
rm -f "$HARNESS_TASK_FILE"

# task-gate-reminder
mkdir -p "$T/work"
( cd "$T/work" && TRACKER_AGENT=my-tracker run_hook '{}' bash "$KIT/hooks/task-gate-reminder.sh"; echo "$OUT" > "$T/o1" )
expect "task-gate-reminder: no task prints the reminder with TRACKER_AGENT" $(grep -q "WORKFLOW ENFORCEMENT" "$T/o1" && grep -q "my-tracker" "$T/o1" && echo 0 || echo 1)
( cd "$T/work" && run_hook '{}' bash "$KIT/hooks/task-gate-reminder.sh"; echo "$OUT" > "$T/o2" )
expect "task-gate-reminder: second call the same day is silent (lock)" $([ -z "$(tr -d '[:space:]' < "$T/o2")" ] && echo 0 || echo 1)

# session-start + brain fixtures
mkdir -p "$BRAIN_DIR/session-checkpoints" "$BRAIN_DIR/sessions" "$BRAIN_DIR/telos"
printf '{"session_id":"old","last_active":"2020-01-01T00:00:00Z"}' > "$BRAIN_DIR/session-checkpoints/old.json"
run_hook '{}' bash "$KIT/hooks/session-start.sh"
expect "session-start: reports 1 orphaned checkpoint" $(contains "$OUT" "ORPHANED SESSIONS: Found 1" && echo 0 || echo 1) "$OUT"
run_hook '{}' bash "$KIT/hooks/session-start.sh"
expect "session-start: second call the same day is silent (lock)" $([ -z "$OUT" ] && echo 0 || echo 1) "$OUT"

# brain-loaded
printf -- '---\ntype: session\n---\n' > "$BRAIN_DIR/sessions/2025-01-15-09.md"
printf '# Recent\n\n## Open Threads\n- first thread\n- second thread\n\n## Recent Decisions\n- one\n' > "$BRAIN_DIR/RECENT.md"
printf -- '---\ntelos_section: identity\nstability: volatile\nlast_reviewed: 2025-01-01\n---\n' > "$BRAIN_DIR/telos/10-identity.md"
run_hook '{}' bash "$KIT/hooks/brain-loaded.sh"
MSG="$(printf '%s' "$OUT" | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{console.log(JSON.parse(d).systemMessage)}catch(e){console.log('PARSE ERROR')}})")"
expect "brain-loaded: status line shows date, threads, overdue file, orphans" $(contains "$MSG" "last session 2025-01-15" && contains "$MSG" "2 open threads" && contains "$MSG" "TELOS overdue: 10-identity" && contains "$MSG" "1 unpromoted" && echo 0 || echo 1) "$MSG"

# checkpoint-session + session-end (negative case in a brain without an epilogue)
SID='{"session_id":"selftest-sid","transcript_path":"t.jsonl","cwd":"somewhere"}'
run_hook "$SID" bash "$KIT/hooks/checkpoint-session.sh"
expect "checkpoint-session: writes <session_id>.json" $([ "$RC" -eq 0 ] && grep -q '"selftest-sid"' "$BRAIN_DIR/session-checkpoints/selftest-sid.json" && echo 0 || echo 1)
BRAIN_DIR="$T/brain2" run_hook "$SID" bash "$KIT/hooks/checkpoint-session.sh"
BRAIN_DIR="$T/brain2" run_hook "$SID" bash "$KIT/hooks/session-end.sh"
expect "session-end: no epilogue leaves the checkpoint in place" $([ -f "$T/brain2/session-checkpoints/selftest-sid.json" ] && echo 0 || echo 1)
run_hook "$SID" bash "$KIT/hooks/session-end.sh"
expect "session-end: recent epilogue archives the checkpoint" $([ -f "$BRAIN_DIR/session-checkpoints/processed/selftest-sid.json" ] && [ ! -f "$BRAIN_DIR/session-checkpoints/selftest-sid.json" ] && echo 0 || echo 1)

# filter-noisy-bash
run_hook '{"tool_input":{"command":"npm run build"}}' bash "$KIT/hooks/filter-noisy-bash.sh"
expect "filter-noisy-bash: warns on an unfiltered build, exit 0" $([ "$RC" -eq 0 ] && contains "$ERR" "NOISY-COMMAND" && echo 0 || echo 1) "rc=$RC"
run_hook '{"tool_input":{"command":"npm run build 2>&1 | tail -5"}}' bash "$KIT/hooks/filter-noisy-bash.sh"
expect "filter-noisy-bash: silent when already filtered" $([ -z "$ERR" ] && echo 0 || echo 1) "$ERR"
EXTRA_NOISY_RE='myplatform deploy' run_hook '{"tool_input":{"command":"myplatform deploy"}}' bash "$KIT/hooks/filter-noisy-bash.sh"
expect "filter-noisy-bash: EXTRA_NOISY_RE is honored" $(contains "$ERR" "NOISY-COMMAND" && echo 0 || echo 1)

# pre-deploy-validate (inside a throwaway git repo with an untracked file)
mkdir -p "$T/repo" && ( cd "$T/repo" && git init -q . 2>/dev/null && echo x > f.txt )
( cd "$T/repo" && run_hook '{"tool_input":{"command":"clever deploy"}}' bash "$KIT/hooks/pre-deploy-validate.sh"; printf '%s\n%s' "$RC" "$ERR" > "$T/o3" )
expect "pre-deploy-validate: warns about a dirty tree, exit 0" $([ "$(head -1 "$T/o3")" = "0" ] && grep -q "Uncommitted" "$T/o3" && echo 0 || echo 1)
( cd "$T/repo" && run_hook '{"tool_input":{"command":"ls"}}' bash "$KIT/hooks/pre-deploy-validate.sh"; printf '%s' "$ERR" > "$T/o4" )
expect "pre-deploy-validate: silent on non-deploy commands" $([ ! -s "$T/o4" ] && echo 0 || echo 1)
( cd "$T/repo" && DEPLOY_CMD_REGEX='myship' run_hook '{"tool_input":{"command":"myship now"}}' bash "$KIT/hooks/pre-deploy-validate.sh"; printf '%s' "$ERR" > "$T/o5" )
expect "pre-deploy-validate: DEPLOY_CMD_REGEX is honored" $(grep -q "Uncommitted" "$T/o5" && echo 0 || echo 1)

# git-commit-reminder
TRACKER_UPDATE_CMD=/task-update run_hook '{"tool_input":{"command":"git commit -m x"}}' bash "$KIT/hooks/git-commit-reminder.sh"
expect "git-commit-reminder: reminds after git commit" $([ "$RC" -eq 0 ] && contains "$ERR" "just committed" && contains "$ERR" "/task-update" && echo 0 || echo 1) "$ERR"
run_hook '{"tool_input":{"command":"git status"}}' bash "$KIT/hooks/git-commit-reminder.sh"
expect "git-commit-reminder: silent for other commands" $([ -z "$ERR" ] && echo 0 || echo 1)

# design-lint-hook (blocking gate)
mkdir -p "$T/ui" && cp "$KIT/scripts/fixtures/bad.css" "$T/ui/bad.css" && cp "$KIT/scripts/fixtures/good.css" "$T/ui/good.css"
run_hook "{\"tool_input\":{\"file_path\":\"$T/ui/bad.css\"}}" bash "$KIT/hooks/design-lint-hook.sh"
expect "design-lint-hook: ERROR findings exit 2 and explain on stderr" $([ "$RC" -eq 2 ] && contains "$ERR" "design-lint BLOCKING" && echo 0 || echo 1) "rc=$RC"
run_hook "{\"tool_input\":{\"file_path\":\"$T/ui/good.css\"}}" bash "$KIT/hooks/design-lint-hook.sh"
expect "design-lint-hook: clean file exits 0" $([ "$RC" -eq 0 ] && echo 0 || echo 1) "rc=$RC"
run_hook "{\"tool_input\":{\"file_path\":\"$KIT/scripts/fixtures/bad.css\"}}" bash "$KIT/hooks/design-lint-hook.sh"
expect "design-lint-hook: fixtures are never linted" $([ "$RC" -eq 0 ] && echo 0 || echo 1) "rc=$RC"

# frontend-format + frontend-typecheck (no formatter installed, then a fake tsc)
mkdir -p "$T/proj/src" && printf '{}' > "$T/proj/package.json" && printf '{}' > "$T/proj/tsconfig.json" && printf 'export const a = 1\n' > "$T/proj/src/a.ts"
FMT="{\"session_id\":\"sid-tc\",\"tool_input\":{\"file_path\":\"$T/proj/src/a.ts\"}}"
run_hook "$FMT" bash "$KIT/hooks/frontend-format.sh"
expect "frontend-format: exit 0 and records the touched project root" $([ "$RC" -eq 0 ] && grep -q "proj" "$HOME/.claude/state/frontend-touched.sid-tc" && echo 0 || echo 1) "rc=$RC"
run_hook '{"session_id":"sid-tc"}' bash "$KIT/hooks/frontend-typecheck.sh"
expect "frontend-typecheck: no tsc available is not an error" $([ "$RC" -eq 0 ] && echo 0 || echo 1) "rc=$RC out=$OUT"
mkdir -p "$T/proj/node_modules/.bin"
printf '#!/bin/sh\necho "src/a.ts(1,1): error TS1000: fake"\nexit 2\n' > "$T/proj/node_modules/.bin/tsc"
chmod +x "$T/proj/node_modules/.bin/tsc"
run_hook "$FMT" bash "$KIT/hooks/frontend-format.sh"
run_hook '{"session_id":"sid-tc"}' bash "$KIT/hooks/frontend-typecheck.sh"
expect "frontend-typecheck: type errors produce a block decision (round 1)" $(contains "$OUT" '"decision":"block"' && echo 0 || echo 1) "$OUT"
run_hook "$FMT" bash "$KIT/hooks/frontend-format.sh"
run_hook '{"session_id":"sid-tc","stop_hook_active":true}' bash "$KIT/hooks/frontend-typecheck.sh"
expect "frontend-typecheck: round 2 still blocks" $(contains "$OUT" '"decision":"block"' && echo 0 || echo 1) "$OUT"
run_hook "$FMT" bash "$KIT/hooks/frontend-format.sh"
run_hook '{"session_id":"sid-tc","stop_hook_active":true}' bash "$KIT/hooks/frontend-typecheck.sh"
expect "frontend-typecheck: cap reached, stop is allowed" $([ "$RC" -eq 0 ] && ! contains "$OUT" '"decision"' && contains "$OUT" "not blocking again" && echo 0 || echo 1) "$OUT"

# dev-server-reaper (dry run; real work only on Windows)
run_hook '{"reason":"other"}' node "$KIT/hooks/dev-server-reaper.mjs" --dry-run
expect "dev-server-reaper: dry run exits 0 (WINDOWS-ONLY logic)" $([ "$RC" -eq 0 ] && echo 0 || echo 1) "rc=$RC $ERR"

# audit-report
mkdir -p "$HOME/.claude/logs"
printf 'branch-divergence-audit x\nDIVERGED: example-repo: 1 commit(s) only on master, 0 only on main\nRESULT: 1 divergent repo(s): example-repo\n' > "$HOME/.claude/logs/branch-divergence-latest.txt"
run_hook '{}' node "$KIT/hooks/audit-report.mjs"
expect "audit-report: announces new findings once" $(contains "$OUT" "NEW FINDINGS" && echo 0 || echo 1) "$OUT"
run_hook '{}' node "$KIT/hooks/audit-report.mjs"
expect "audit-report: second run is silent (marker)" $([ -z "$OUT" ] && echo 0 || echo 1) "$OUT"

echo "== scripts =="
S="$KIT/scripts/task-state.sh"
bash "$S" init T-9 "Demo task" >/dev/null 2>&1
expect "task-state init: writes the companion files" $([ "$(cat "$HARNESS_TASK_FILE")" = "T-9" ] && [ "$(cat "$HARNESS_TASK_FILE-status")" = "DOING" ] && [ -f "$HARNESS_TASK_FILE-due" ] && echo 0 || echo 1)
bash "$S" step implement >/dev/null 2>&1
expect "task-state step: updates the step file" $([ "$(cat "$HARNESS_TASK_FILE-step")" = "implement" ] && echo 0 || echo 1)
mkdir -p "$HOME/.claude" && cp "$KIT"/statusline/statusline.* "$HOME/.claude/"
OUT="$(printf '%s' '{"model":{"display_name":"Claude Test"},"context_window":{"used_percentage":42},"cost":{"total_cost_usd":0.5},"session_id":"sl-1"}' | bash "$HOME/.claude/statusline.sh" 2>&1)"
expect "statusline: renders the active task and context percentage" $(contains "$OUT" "Demo task" && contains "$OUT" "42%" && echo 0 || echo 1) "$OUT"
bash "$S" shipped >/dev/null 2>&1
expect "task-state shipped: logs and clears" $([ -f "$HOME/.claude/shipped-log" ] && [ ! -f "$HARNESS_TASK_FILE" ] && echo 0 || echo 1)
OUT="$(printf '%s' '{}' | bash "$HOME/.claude/statusline.sh" 2>&1)"
expect "statusline: shows 'no active task' when idle" $(contains "$OUT" "no active task" && echo 0 || echo 1) "$OUT"

echo "== isolation =="
expect "real home untouched (no selftest checkpoint in the real brain)" $([ ! -e "$REAL_HOME/brain/session-checkpoints/selftest-sid.json" ] && echo 0 || echo 1)

echo
echo "selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
