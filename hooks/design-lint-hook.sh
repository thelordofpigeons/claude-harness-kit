#!/usr/bin/env bash
# design-lint-hook.sh: PostToolUse hook (Edit|Write) for styling files.
# Reads the hook JSON payload from stdin, extracts .tool_input.file_path
# (no jq dependency), and runs the design-slop linter.
#
# BLOCKING on ERROR: any [ERROR] finding (banned font,
# raw hex in a component, transition: all, ...) exits 2 so the findings are
# fed back to Claude as a blocking error it must act on. WARN findings stay
# advisory (stdout, exit 0). Rationale: prose rules in a router file get skipped,
# so the one mechanical gate on UI output must actually bite.
#
# DESIGN_LINT (env) overrides the linter path; default ~/.claude/scripts/design-lint.mjs.

payload="$(cat 2>/dev/null || true)"

fp="$(printf '%s' "$payload" \
  | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' \
  | head -n1 \
  | sed -e 's/^"file_path"[[:space:]]*:[[:space:]]*"//' -e 's/"$//')"

[ -n "$fp" ] || exit 0

# Normalize backslashes (JSON-escaped \\ or raw \) to forward slashes.
fp="$(printf '%s' "$fp" | tr '\\' '/' | sed 's#//*#/#g')"

# Only lint styling-relevant extensions.
case "$fp" in
  *.css|*.scss|*.tsx|*.jsx|*.html|*.vue|*.svelte) : ;;
  *) exit 0 ;;
esac

# Never lint the linter's own fixtures (they are intentionally bad).
case "$fp" in
  */scripts/fixtures/*) exit 0 ;;
esac

# Skip generated / vendored output.
case "$fp" in
  */node_modules/*|*/dist/*|*/build/*|*/.next/*) exit 0 ;;
esac

LINT="${DESIGN_LINT:-$HOME/.claude/scripts/design-lint.mjs}"
out="$(node "$LINT" "$fp" 2>&1 || true)"
[ -n "$out" ] || exit 0

if printf '%s\n' "$out" | grep -q '\[ERROR\]'; then
  {
    echo "design-lint BLOCKING: the file you just wrote violates hard design rules. Fix every [ERROR] below before continuing (tokens via CSS custom properties or Tailwind theme, no banned fonts, no transition: all):"
    printf '%s\n' "$out" | grep -E '\[(ERROR|WARN)\]|design-lint:'
  } >&2
  exit 2
fi

printf '%s\n' "$out" | sed 's/^/design-lint (advisory): /'
exit 0
