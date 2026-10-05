#!/bin/bash
# Smoke test for telos-check.ps1.
# Builds a throwaway memory folder from telos-templates/ in a temp dir, points BRAIN_DIR at it,
# and runs the validator against a good state and a mutated (missing-file) state.
# Never touches a real memory folder. Needs PowerShell (pwsh or powershell.exe) on PATH.
# Usage: bash memory/telos-check.test.sh

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/telos-check.ps1"
TEMPLATES="$HERE/telos-templates"

PS=""
for cand in pwsh powershell.exe powershell; do
  if command -v "$cand" >/dev/null 2>&1; then PS="$cand"; break; fi
done
if [ -z "$PS" ]; then
  echo "SKIP: no PowerShell on PATH"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/telos"
cp "$TEMPLATES"/*.md "$TMP/telos/"
printf 'telos/sensitive/\n' > "$TMP/.gitignore"

to_native() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

run_ps() {
  BRAIN_DIR="$(to_native "$TMP")" USERPROFILE="${USERPROFILE:-$HOME}" \
    "$PS" -NoProfile -ExecutionPolicy Bypass -File "$(to_native "$SCRIPT")" 2>&1
  return $?
}

FAILED=0

echo "TEST 1: baseline (all files present) should exit 0"
run_ps >/dev/null
if [ $? -eq 0 ]; then echo "  PASS"; else echo "  FAIL (expected exit 0)"; FAILED=1; fi

echo "TEST 2: missing 10-identity.md should exit non-zero"
mv "$TMP/telos/10-identity.md" "$TMP/telos/10-identity.md.bak"
run_ps >/dev/null
RESULT=$?
mv "$TMP/telos/10-identity.md.bak" "$TMP/telos/10-identity.md"
if [ $RESULT -ne 0 ]; then echo "  PASS"; else echo "  FAIL (expected non-zero exit when a file is missing)"; FAILED=1; fi

echo "TEST 3: gitignore verification reports sensitive/ as ignored"
if run_ps | grep -qi "sensitive.*ignored"; then echo "  PASS"; else echo "  FAIL (expected output mentioning sensitive being ignored)"; FAILED=1; fi

echo "TEST 4: missing .gitignore should exit non-zero"
rm -f "$TMP/.gitignore"
run_ps >/dev/null
if [ $? -ne 0 ]; then echo "  PASS"; else echo "  FAIL (expected non-zero exit without .gitignore)"; FAILED=1; fi

if [ $FAILED -eq 0 ]; then
  echo "ALL TESTS PASSED"
  exit 0
else
  echo "SOME TESTS FAILED"
  exit 1
fi
