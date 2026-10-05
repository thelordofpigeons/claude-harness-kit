#!/usr/bin/env bash
# check_all.sh: run every verification the kit has, print PASS/FAIL per step, exit non-zero on any failure.
#
# Steps:
#   1. denylist present (--strict only; the denylist lives outside the repo folder, see leak_scan.py)
#   2. leak_scan.py   private material in the tree
#   3. dash_scan.py   dashes, emoji, BOM, CR, size, final newline
#   4. syntax         bash -n on shell scripts, node --check on .mjs files
#   5. selftest.sh    design-lint fixtures and hook smoke tests (if present)
#   6. telos-check    validator against a temporary copy of the templates (needs PowerShell)
#   7. pytest         memory/tests and tools/hygiene/tests
#
# Usage: bash tools/hygiene/check_all.sh [--strict]
# --strict: a missing denylist, selftest.sh or pytest is a failure instead of a skip.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$ROOT" || exit 2

STRICT=0
[ "${1:-}" = "--strict" ] && STRICT=1

PY=""
for cand in python3 python py; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' >/dev/null 2>&1; then
    PY="$cand"
    break
  fi
done
if [ -z "$PY" ]; then
  echo "FAIL: no usable python (3.9 or newer) on PATH"
  exit 2
fi

export PYTHONDONTWRITEBYTECODE=1
# Hermetic test run: ignore pytest plugins installed on the machine.
export PYTEST_DISABLE_PLUGIN_AUTOLOAD=1

FAILED=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILED=1; }
skip() { echo "SKIP  $1"; }

# 1. denylist
DENYLIST="${KIT_DENYLIST:-$HOME/.config/claude-harness-kit/denylist.txt}"
[ -f "$DENYLIST" ] || DENYLIST=".hygiene/denylist.txt"
if [ -f "$DENYLIST" ]; then
  pass "denylist present"
elif [ $STRICT -eq 1 ]; then
  fail "denylist missing (set KIT_DENYLIST or create ~/.config/claude-harness-kit/denylist.txt), strict mode"
else
  skip "denylist missing, rule R1 not checked"
fi

# 2. leak scan
LEAK_ARGS=()
[ $STRICT -eq 1 ] && LEAK_ARGS+=(--strict)
if "$PY" tools/hygiene/leak_scan.py ${LEAK_ARGS[@]+"${LEAK_ARGS[@]}"}; then pass "leak_scan"; else fail "leak_scan"; fi

# 3. dash scan
if "$PY" tools/hygiene/dash_scan.py; then pass "dash_scan"; else fail "dash_scan"; fi

# 4. syntax checks
SYNTAX_OK=1
while IFS= read -r f; do
  bash -n "$f" || { echo "  bash -n failed: $f"; SYNTAX_OK=0; }
done < <(find . -name '*.sh' -not -path './.git/*' -not -path './node_modules/*' | sort)
if command -v node >/dev/null 2>&1; then
  while IFS= read -r f; do
    node --check "$f" || { echo "  node --check failed: $f"; SYNTAX_OK=0; }
  done < <(find . -name '*.mjs' -not -path './.git/*' -not -path './node_modules/*' | sort)
else
  echo "  node not found, skipped .mjs syntax checks"
fi
while IFS= read -r f; do
  "$PY" -m py_compile "$f" || { echo "  py_compile failed: $f"; SYNTAX_OK=0; }
done < <(find . -name '*.py' -not -path './.git/*' | sort)
find . -name '__pycache__' -type d -not -path './.git/*' -prune -exec rm -rf {} + 2>/dev/null
[ $SYNTAX_OK -eq 1 ] && pass "syntax" || fail "syntax"

# 5. selftest
if [ -f scripts/selftest.sh ]; then
  if bash scripts/selftest.sh; then pass "scripts/selftest.sh"; else fail "scripts/selftest.sh"; fi
elif [ $STRICT -eq 1 ]; then
  fail "scripts/selftest.sh missing, strict mode"
else
  skip "scripts/selftest.sh missing"
fi

# 6. telos validator (prints SKIP and exits 0 when PowerShell is absent)
if [ -f memory/telos-check.test.sh ]; then
  if bash memory/telos-check.test.sh; then pass "telos-check.test.sh"; else fail "telos-check.test.sh"; fi
fi

# 7. pytest
if "$PY" -m pytest --version >/dev/null 2>&1; then
  if "$PY" -m pytest memory/tests tools/hygiene/tests -q -p no:cacheprovider; then pass "pytest"; else fail "pytest"; fi
elif [ $STRICT -eq 1 ]; then
  fail "pytest not installed, strict mode"
else
  skip "pytest not installed"
fi

echo
if [ $FAILED -eq 0 ]; then
  echo "check_all: ALL PASSED"
  exit 0
fi
echo "check_all: FAILURES"
exit 1
