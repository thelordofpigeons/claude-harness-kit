#!/usr/bin/env bash
# pre-deploy-validate.sh: PreToolUse hook on Bash. ADVISORY ONLY, always exits 0.
# TEMPLATE: parameters DEPLOY_CMD_REGEX (extended regex that marks a deploy
#           command, default 'clever deploy', a Clever Cloud CLI example),
#           DEPLOY_AUTH_CHECK (optional shell snippet; a non-zero exit prints an
#           auth warning, replaces the built-in Clever Cloud example check).
#
# Fires on a command matching DEPLOY_CMD_REGEX, or on a force push to master.
# Warns about: dirty working tree, Drizzle journal entries without SQL files,
# diverged main/master, pushing a branch other than the checked-out one, and
# missing deploy auth. It exists to stop deploys of the wrong branch.
#
# Activation: register it in your settings file under hooks.PreToolUse with
# matcher "Bash" (see settings.example.json).

DEPLOY_CMD_REGEX="${DEPLOY_CMD_REGEX:-clever deploy}"

# Read the triggering command from stdin (Claude Code passes hook input as JSON).
# Prefer jq (survives escaped quotes inside the command); fall back to a
# whitespace-tolerant grep, then to raw stdin.
INPUT=$(cat)
COMMAND=""
if command -v jq >/dev/null 2>&1; then
    COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
fi
if [ -z "$COMMAND" ]; then
    COMMAND=$(printf '%s' "$INPUT" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/^"command"[[:space:]]*:[[:space:]]*"//;s/"$//')
fi
if [ -z "$COMMAND" ]; then
    COMMAND=$INPUT
fi

# Check if this hook should fire
IS_DEPLOY=0
IS_CUSTOM_DEPLOY=0
if printf '%s' "$COMMAND" | grep -qE "$DEPLOY_CMD_REGEX"; then
    IS_DEPLOY=1
    IS_CUSTOM_DEPLOY=1
elif printf '%s' "$COMMAND" | grep -q "git push" && \
     printf '%s' "$COMMAND" | grep -q "master" && \
     printf '%s' "$COMMAND" | grep -q "force"; then
    IS_DEPLOY=1
fi

if [ "$IS_DEPLOY" -eq 0 ]; then
    exit 0
fi

warn() { printf 'pre-deploy-validate: WARNING: %s\n' "$*" >&2; }

# Run checks from the session cwd Claude Code passes in the hook input;
# the hook process itself may start elsewhere (e.g. the user's home dir).
HOOK_CWD=""
if command -v jq >/dev/null 2>&1; then
    HOOK_CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
fi
if [ -z "$HOOK_CWD" ]; then
    # No jq: extract "cwd" by grep and turn JSON-escaped backslashes into
    # forward slashes (git-bash accepts both as path separators)
    HOOK_CWD=$(printf '%s' "$INPUT" \
        | grep -o '"cwd"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | sed 's/^"cwd"[[:space:]]*:[[:space:]]*"//;s/"$//;s/\\\\/\//g')
fi
[ -n "$HOOK_CWD" ] && [ -d "$HOOK_CWD" ] && cd "$HOOK_CWD" 2>/dev/null

# ---------------------------------------------------------------------------
# Check 1: dirty working tree
# ---------------------------------------------------------------------------
DIRTY=$(git status --porcelain 2>/dev/null)
if [ -n "$DIRTY" ]; then
    warn "Uncommitted changes detected. Consider stashing or committing before deploying."
fi

# ---------------------------------------------------------------------------
# Check 2: Drizzle journal integrity (drizzle-kit is public tooling)
# drizzle-kit pretty-prints the journal ("tag": "...") and puts .sql files in
# the PARENT of meta/, so tolerate whitespace and check both locations.
# Scope the scan to the git repo root: an unbounded `find .` from a broad
# cwd (e.g. $HOME) walks the entire tree and can stall the hook for minutes.
# Outside a repo there is nothing to deploy from, so skip the check.
# ---------------------------------------------------------------------------
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
JOURNAL_FILES=""
if [ -n "$REPO_ROOT" ]; then
    JOURNAL_FILES=$(find "$REPO_ROOT" -name "_journal.json" -not -path "*/node_modules/*" 2>/dev/null)
fi
if [ -n "$JOURNAL_FILES" ]; then
    while IFS= read -r JOURNAL_PATH; do
        [ -z "$JOURNAL_PATH" ] && continue
        JOURNAL_DIR=$(dirname "$JOURNAL_PATH")
        MIGRATIONS_DIR=$(dirname "$JOURNAL_DIR")

        # Extract tags from .entries[].tag (whitespace-tolerant)
        if command -v jq >/dev/null 2>&1; then
            TAGS=$(jq -r '.entries[].tag' "$JOURNAL_PATH" 2>/dev/null)
        else
            TAGS=$(grep -o '"tag"[[:space:]]*:[[:space:]]*"[^"]*"' "$JOURNAL_PATH" 2>/dev/null | sed 's/.*"\([^"]*\)"$/\1/')
        fi

        while IFS= read -r TAG; do
            [ -z "$TAG" ] && continue
            # drizzle-kit layout: drizzle/<tag>.sql (sibling of meta/);
            # also accept <tag>.sql next to the journal for custom layouts
            if [ ! -f "${MIGRATIONS_DIR}/${TAG}.sql" ] && [ ! -f "${JOURNAL_DIR}/${TAG}.sql" ]; then
                warn "Journal tag ${TAG} has no matching SQL file. This may cause migrations to be skipped."
            fi
        done <<< "$TAGS"
    done <<< "$JOURNAL_FILES"
fi

# ---------------------------------------------------------------------------
# Check 3: main/master divergence
# Wrong-branch deploys waste hours of debugging. Warn when both branches exist
# and have diverged, or when the push refspec source is not the branch
# currently checked out.
# ---------------------------------------------------------------------------
if [ -n "$REPO_ROOT" ]; then
    CUR_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null)
    if git show-ref --verify --quiet refs/heads/main && git show-ref --verify --quiet refs/heads/master; then
        COUNTS=$(git rev-list --left-right --count main...master 2>/dev/null)
        AHEAD=$(printf '%s' "$COUNTS" | awk '{print $1}')
        BEHIND=$(printf '%s' "$COUNTS" | awk '{print $2}')
        if [ "${AHEAD:-0}" != "0" ] || [ "${BEHIND:-0}" != "0" ]; then
            warn "main and master BOTH exist and have DIVERGED (main +${AHEAD:-?} / master +${BEHIND:-?}). Verify you are deploying the branch you think you are (current: ${CUR_BRANCH:-detached})."
        fi
    fi
    if printf '%s' "$COMMAND" | grep -q "git push"; then
        SRC=$(printf '%s' "$COMMAND" | grep -oE '[A-Za-z0-9_./-]+:master' | head -1 | cut -d: -f1)
        if [ -n "$SRC" ] && [ -n "$CUR_BRANCH" ] && [ "$SRC" != "$CUR_BRANCH" ] && [ "$SRC" != "HEAD" ]; then
            warn "Pushing branch ${SRC} to remote master while checked out on ${CUR_BRANCH}. Confirm this is intentional."
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Check 4: deploy auth (platform specific)
# If DEPLOY_AUTH_CHECK is set, run it and warn on a non-zero exit. Otherwise a
# built-in example for the Clever Cloud CLI runs when the command looks like
# `clever deploy`, and an SSH-agent check runs for plain `git push` deploys.
# ---------------------------------------------------------------------------
if [ -n "${DEPLOY_AUTH_CHECK:-}" ]; then
    if [ "$IS_CUSTOM_DEPLOY" -eq 1 ] && ! bash -c "$DEPLOY_AUTH_CHECK" >/dev/null 2>&1; then
        warn "DEPLOY_AUTH_CHECK failed. Authenticate with your deploy tool first."
    fi
elif printf '%s' "$COMMAND" | grep -q "clever deploy"; then
    # Example: Clever Cloud CLI is authenticated via the config file written by
    # `clever login` (interactive) or CLEVER_TOKEN/CLEVER_SECRET env vars (CI).
    CLEVER_CONFIG_UNIX="$HOME/.config/clever-cloud/clever-tools.json"
    CLEVER_CONFIG_WIN="${APPDATA:-}/clever-cloud/clever-tools.json"
    if [ -z "${CLEVER_TOKEN:-}" ] && [ ! -f "$CLEVER_CONFIG_UNIX" ] && [ ! -f "$CLEVER_CONFIG_WIN" ]; then
        warn "No clever-tools login config found and CLEVER_TOKEN not set. Run \`clever login\` first."
    fi
elif printf '%s' "$COMMAND" | grep -q "git push"; then
    # SSH method
    SSH_KEYS=""
    SSH_KEYS=$(ssh-add -l 2>/dev/null) || true
    if [ -z "$SSH_KEYS" ] && [ -z "${GIT_SSH_COMMAND:-}" ]; then
        warn "No SSH keys loaded and GIT_SSH_COMMAND not set. SSH push may fail."
    fi
fi

exit 0
