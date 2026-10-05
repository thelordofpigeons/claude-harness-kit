#!/usr/bin/env bash
# frontend-format.sh: PostToolUse hook (Edit|Write).
# After Claude touches a frontend source file inside a Node project, run the
# project's OWN prettier and eslint --fix on that one file (only if the project
# has them installed; never installs anything). Also drops a marker so the
# Stop-time typecheck hook (frontend-typecheck.sh) knows which project roots
# were touched this session. Always exits 0; formatting is never a reason to
# block. JSON fields are pulled out with grep/sed instead of jq so the hook has
# no dependency beyond a POSIX shell (file paths and session ids contain no quotes).
# Pattern: code.claude.com/docs/en/hooks-guide (format on PostToolUse,
# typecheck on Stop, never tsc per-edit).

payload="$(cat 2>/dev/null || true)"

fp="$(printf '%s' "$payload" \
  | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' \
  | head -n1 \
  | sed -e 's/^"file_path"[[:space:]]*:[[:space:]]*"//' -e 's/"$//')"
sid="$(printf '%s' "$payload" \
  | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' \
  | head -n1 \
  | sed -e 's/^"session_id"[[:space:]]*:[[:space:]]*"//' -e 's/"$//')"

[ -n "$fp" ] || exit 0
fp="$(printf '%s' "$fp" | tr '\\' '/' | sed 's#//*#/#g')"

case "$fp" in
  *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.css|*.scss|*.vue|*.svelte|*.astro) : ;;
  *) exit 0 ;;
esac
case "$fp" in
  */node_modules/*|*/dist/*|*/build/*|*/.next/*|*/.claude/*) exit 0 ;;
esac
[ -f "$fp" ] || exit 0

# Walk up to the nearest package.json (max 8 levels).
root="$(dirname "$fp")"
found=""
for _ in 1 2 3 4 5 6 7 8; do
  if [ -f "$root/package.json" ]; then found="$root"; break; fi
  parent="$(dirname "$root")"
  [ "$parent" = "$root" ] && break
  root="$parent"
done
[ -n "$found" ] || exit 0
root="$found"

# Locate a binary in node_modules/.bin starting at root and walking up (monorepos hoist).
find_bin() {
  local d="$root" i
  for i in 1 2 3 4 5; do
    if [ -f "$d/node_modules/.bin/$1" ]; then printf '%s' "$d/node_modules/.bin/$1"; return 0; fi
    local parent; parent="$(dirname "$d")"
    [ "$parent" = "$d" ] && break
    d="$parent"
  done
  return 1
}
prettier_bin="$(find_bin prettier || true)"
eslint_bin="$(find_bin eslint || true)"

ran=""
if [ -n "$prettier_bin" ]; then
  if timeout 20 "$prettier_bin" --write --log-level warn "$fp" >/dev/null 2>&1; then ran="prettier"; fi
fi

has_eslint_cfg=""
for c in eslint.config.js eslint.config.mjs eslint.config.cjs eslint.config.ts .eslintrc .eslintrc.js .eslintrc.cjs .eslintrc.json .eslintrc.yml .eslintrc.yaml; do
  [ -f "$root/$c" ] && has_eslint_cfg=1 && break
done
if [ -n "$has_eslint_cfg" ] && [ -n "$eslint_bin" ]; then
  case "$fp" in
    *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.vue|*.svelte|*.astro)
      es_out="$(cd "$root" && timeout 40 "$eslint_bin" --fix --no-warn-ignored "$fp" 2>&1 | grep -E 'error' | head -12)"
      ran="${ran:+$ran, }eslint --fix"
      ;;
  esac
fi

# Marker for the Stop-time typecheck (one root per line, deduped).
if [ -n "$sid" ] && [ -f "$root/tsconfig.json" ]; then
  mkdir -p "$HOME/.claude/state"
  marker="$HOME/.claude/state/frontend-touched.$sid"
  grep -qxF "$root" "$marker" 2>/dev/null || printf '%s\n' "$root" >> "$marker"
fi

if [ -n "$ran" ]; then
  echo "frontend-format: $ran on $(basename "$fp")"
  [ -n "$es_out" ] && printf '%s\n' "$es_out" | sed 's/^/  eslint: /'
fi
exit 0
