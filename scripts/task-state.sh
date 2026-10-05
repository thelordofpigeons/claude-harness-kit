#!/bin/bash
# task-state.sh: manage the active-task companion files read by statusline.mjs.
# TEMPLATE: parameters HARNESS_TASK_FILE (base file, default
#           ${CLAUDE_HOME:-~/.claude}/current-task), TASK_DEFAULT_STATUS
#           (default "DOING"), CLAUDE_HOME.
#
# The status line shows the active task's name, status, step (workflow progress
# bar), due-date countdown and a stale-task alert. It reads each field from a
# separate file next to the base task file: <base>-name, -status, -step, -start,
# -due. This helper keeps those files in sync at workflow lifecycle moments.
#
# Usage:
#   task-state.sh init   <ID> <NAME> [STATUS] [STEP] [DUE_DAYS]
#   task-state.sh status <STATUS> [STEP]
#   task-state.sh step   <STEP>
#   task-state.sh shipped              (logs to shipped-log, clears all files)
#   task-state.sh clear                (clears all files, no log entry)
#
# Defaults: STATUS=$TASK_DEFAULT_STATUS, STEP="task_created", DUE_DAYS=7
#
# STATUS is free text. Example lifecycle (replace with your tracker's):
#   TODO -> DOING -> REVIEW -> VERIFY -> DONE
# statusline.mjs colors known statuses; see STATUS_COLORS there.
#
# Allowed STEP values (must match STEP_MAP in statusline.mjs):
#   design plan task_created tests implement review security committed
#   in_review docs testing shipped

set -euo pipefail

CLAUDE_DIR="${CLAUDE_HOME:-$HOME/.claude}"
BASE="${HARNESS_TASK_FILE:-$CLAUDE_DIR/current-task}"
DEFAULT_STATUS="${TASK_DEFAULT_STATUS:-DOING}"
SHIPPED_LOG="$(dirname "$BASE")/shipped-log"
FILES=(
  "$BASE"
  "${BASE}-name"
  "${BASE}-status"
  "${BASE}-step"
  "${BASE}-start"
  "${BASE}-due"
)

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

due_iso() {
  local days="$1"
  # GNU date (Linux / Git Bash) first, fall back to BSD date (macOS).
  date -u -d "+${days} days" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -v+"${days}"d +"%Y-%m-%dT%H:%M:%SZ"
}

cmd="${1:-}"
shift || true

case "$cmd" in
  init)
    id="${1:-}"; name="${2:-}"
    status="${3:-$DEFAULT_STATUS}"
    step="${4:-task_created}"
    due_days="${5:-7}"
    if [ -z "$id" ] || [ -z "$name" ]; then
      echo "usage: task-state.sh init <ID> <NAME> [STATUS] [STEP] [DUE_DAYS]" >&2
      exit 2
    fi
    mkdir -p "$(dirname "$BASE")"
    printf '%s' "$id"     > "$BASE"
    printf '%s' "$name"   > "${BASE}-name"
    printf '%s' "$status" > "${BASE}-status"
    printf '%s' "$step"   > "${BASE}-step"
    now_iso               > "${BASE}-start"
    due_iso "$due_days"   > "${BASE}-due"
    echo "active task: $id ($status, step=$step, due in ${due_days}d)"
    ;;

  status)
    status="${1:-}"
    step="${2:-}"
    if [ -z "$status" ]; then
      echo "usage: task-state.sh status <STATUS> [STEP]" >&2
      exit 2
    fi
    printf '%s' "$status" > "${BASE}-status"
    if [ -n "$step" ]; then
      printf '%s' "$step" > "${BASE}-step"
    fi
    echo "status -> $status${step:+ (step=$step)}"
    ;;

  step)
    step="${1:-}"
    if [ -z "$step" ]; then
      echo "usage: task-state.sh step <STEP>" >&2
      exit 2
    fi
    printf '%s' "$step" > "${BASE}-step"
    echo "step -> $step"
    ;;

  shipped)
    # Append to shipped-log (used by the status line's weekly count) then clear.
    id=""
    name=""
    [ -f "$BASE" ]        && id="$(tr -d '[:space:]' < "$BASE")"
    [ -f "${BASE}-name" ] && name="$(head -1 "${BASE}-name" | tr -d '\r')"
    ts="$(now_iso)"
    echo "${ts}|${id}|${name}" >> "$SHIPPED_LOG"
    rm -f "${FILES[@]}"
    echo "shipped: $id ($name), logged and cleared"
    ;;

  clear)
    rm -f "${FILES[@]}"
    echo "active task cleared"
    ;;

  *)
    cat >&2 <<EOF
usage:
  task-state.sh init   <ID> <NAME> [STATUS] [STEP] [DUE_DAYS]
  task-state.sh status <STATUS> [STEP]
  task-state.sh step   <STEP>
  task-state.sh shipped
  task-state.sh clear
EOF
    exit 2
    ;;
esac
