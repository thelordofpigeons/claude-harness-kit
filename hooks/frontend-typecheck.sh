#!/usr/bin/env bash
# frontend-typecheck.sh: Stop hook.
# If frontend-format.sh recorded touched TypeScript project roots this
# session, run each project's own `tsc --noEmit` ONCE at stop time (never
# per edit). On errors, block the stop with a JSON decision so Claude fixes
# them; capped at 2 consecutive blocking rounds per session so pre-existing
# type debt can never trap the session in a loop (stop_hook_active + round
# counter). Clean run or cap reached: exit 0.
#
# Dependencies: bash, the project's own node_modules/.bin/tsc, and node (only to
# JSON-escape the reason string; python, then a sed fallback, are tried when node is
# missing). `timeout` (or `gtimeout`) is used when present; macOS has neither by
# default, so tsc then runs without a time limit.

payload="$(cat 2>/dev/null || true)"
sid="$(printf '%s' "$payload" \
  | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 \
  | sed -e 's/^"session_id"[[:space:]]*:[[:space:]]*"//' -e 's/"$//')"
[ -n "$sid" ] || exit 0

state="$HOME/.claude/state"
marker="$state/frontend-touched.$sid"
rounds_f="$state/frontend-tsc-rounds.$sid"
[ -f "$marker" ] || exit 0

rounds=0
[ -f "$rounds_f" ] && rounds="$(cat "$rounds_f" 2>/dev/null || echo 0)"
active="$(printf '%s' "$payload" | grep -o '"stop_hook_active"[[:space:]]*:[[:space:]]*true')"

roots="$(cat "$marker")"
rm -f "$marker"

TMO=()
if command -v timeout >/dev/null 2>&1; then TMO=(timeout 150)
elif command -v gtimeout >/dev/null 2>&1; then TMO=(gtimeout 150); fi

report=""
total=0
unverified=0
while IFS= read -r root; do
  [ -n "$root" ] || continue
  [ -f "$root/tsconfig.json" ] || continue
  tsc=""; d="$root"
  for _ in 1 2 3 4 5; do
    if [ -f "$d/node_modules/.bin/tsc" ]; then tsc="$d/node_modules/.bin/tsc"; break; fi
    parent="$(dirname "$d")"; [ "$parent" = "$d" ] && break; d="$parent"
  done
  [ -n "$tsc" ] || continue
  raw="$(cd "$root" && "${TMO[@]}" "$tsc" --noEmit -p . 2>&1)"
  rc=$?
  out="$(printf '%s\n' "$raw" | grep -E 'error TS' | head -25)"
  n="$(printf '%s' "$out" | grep -c 'error TS' || true)"
  if [ "$n" -eq 0 ] && [ "$rc" -ne 0 ]; then
    # tsc failed without reporting type errors (timeout, crash, missing command):
    # that is not a pass, so say so instead of printing "clean".
    echo "frontend-typecheck: tsc exited $rc without type errors for $root; result unverified" >&2
    unverified=1
  fi
  if [ "$n" -gt 0 ]; then
    total=$((total + n))
    report="${report}
[$root] $n type error(s):
$out"
  fi
done <<< "$roots"

if [ "$total" -eq 0 ]; then
  rm -f "$rounds_f"
  if [ "$unverified" -eq 1 ]; then
    echo "frontend-typecheck: no type errors reported, but at least one tsc run did not finish cleanly"
  else
    echo "frontend-typecheck: tsc clean"
  fi
  exit 0
fi

if [ -n "$active" ] && [ "$rounds" -ge 2 ]; then
  rm -f "$rounds_f"
  echo "frontend-typecheck: $total type error(s) remain after 2 fix rounds; not blocking again this session. Remaining:$report"
  exit 0
fi

echo $((rounds + 1)) > "$rounds_f"
reason="tsc --noEmit found $total type error(s) in files touched this session. Fix them before stopping (round $((rounds + 1))/2).$report"
# JSON-escape the reason: node first (the other hooks need it too), then python.
esc=""
if command -v node >/dev/null 2>&1; then
  esc="$(printf '%s' "$reason" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.stringify(s)))' 2>/dev/null)"
fi
if [ -z "$esc" ]; then
  for py in python3 python; do
    esc="$(printf '%s' "$reason" | "$py" -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null)" && [ -n "$esc" ] && break
  done
fi
if [ -z "$esc" ]; then
  # Last resort: escape backslashes first, then quotes, and flatten control characters.
  esc="\"$(printf '%s' "$reason" | tr '\n\r\t' '   ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')\""
fi
printf '{"decision":"block","reason":%s}\n' "$esc"
exit 0
