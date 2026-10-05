---
name: cc-deploy
description: Deploy an app on Clever Cloud. Covers the clever CLI and SSH git push methods, a pre-deploy validation checklist, why force push is required, multi-key SSH setup, and the post-deploy gates. Triggers on "deploy to test/prod", "push to the platform", "trigger a deploy".
---

TEMPLATE: Clever Cloud is used here as one labeled example of a hosting platform. The structure (pre-deploy checks, two deploy methods, post-deploy gates) carries over to other hosts.
Parameters: `<APP_ID>`, `<ORG>`, `<push-host>`, `<instance-ssh-host>`, `<branch>`, `<tag>`. Fill them from your own console. Flattened from a skill directory; to use it, save it as `skills/cc-deploy/SKILL.md`.

# Clever Cloud deploy

## Pre-deploy validation checklist

Run before every deploy (`hooks/pre-deploy-validate.sh` automates the first two as advisory warnings):
1. **Dirty working tree**: `git status --porcelain`. Warn if there are uncommitted changes.
2. **Journal integrity** (if a `_journal.json` exists): verify each tag has a matching SQL file.
3. **Auth**: `clever profile` exits 0 (CLI; covers both a `clever login` config and the `CLEVER_TOKEN` and `CLEVER_SECRET` variables), or `ssh-add -l` shows a loaded key (SSH).

---

## Method A: `clever` CLI (preferred)

Use when the CLI is installed and authenticated (`clever profile` succeeds).

```bash
# Deploy the current branch
clever deploy -f

# Deploy a specific branch
clever deploy --branch <branch> -f

# Deploy a release tag
clever deploy --tag <tag> -f

# Non-interactive CI auth (values come from CI secrets, never from the repo)
CLEVER_TOKEN=... CLEVER_SECRET=... clever deploy -f
```

**App linking.** `clever deploy` needs to know which app to target. Either the repo is linked (`clever link <APP_ID>` creates `.clever.json`), or pass `--alias` or `-a <alias>` explicitly. In an unlinked directory the deploy fails immediately.

**Redeploying an unchanged commit.** `--same-commit-policy` defaults to `error`, so a redeploy with no new commit fails. Use `clever deploy -f --same-commit-policy rebuild` (full rebuild) or `restart` (reuse the build), for example after changing a build-affecting env var. Two traps: `--force` does not override this policy (it only force-pushes), and without `--verbose` the error can be masked by terse output that reads like a successful deploy. Use `--verbose` for diagnostic deploys.

**GitHub-integrated apps.** If the app deploys through the platform's native GitHub integration, `clever deploy` is rejected with a 401. Deploys only happen by pushing to the tracked GitHub branch. Push there and monitor with `clever activity --app <APP_ID>`.

**Stuck build recovery.** If a deploy hangs in the build phase (for example type validation on a small instance), run `clever cancel-deploy` and then `clever restart`. The cancelled deploy's build cache is preserved, so the retry is much faster than waiting.

**Important.** `clever deploy` exits at deploy-end (build and stream finished), not when the app is healthy. A successful exit does not mean the app is running. Always run the health-check step after (`cc-healthcheck.md`). `--exit-on never` and `--follow` keep the command attached longer if needed.

---

## Method B: SSH git push (fallback)

Use when the CLI is unavailable (some CI environments).

```bash
# With a dedicated key (avoids conflicts with other SSH keys)
GIT_SSH_COMMAND='ssh -i ~/.ssh/<deploy_key> -o IdentitiesOnly=yes' \
  git push git+ssh://git@<push-host>/<APP_ID>.git HEAD:master --force
```

### Getting the SSH host

Read the full push host from the console: App, Information tab, Git deployment URL. Do not hardcode it. Hosts follow a `push-<n>-<zone>-...` pattern, vary by region, and new zones are added over time.

### Two different SSH hosts (do not confuse)

| Purpose | Host |
|---|---|
| Git deploy (push code) | `<push-host>` (from the console) |
| SSH into a running instance | `<instance-ssh-host>` |

Using the instance gateway for git push fails with a confusing auth error.

---

## Why force push is always required

The platform rewrites the remote history on every deployment, so your push is always non-fast-forward. This is expected. Always use `--force` (SSH) or `-f` (CLI).

---

## Post-deploy: three mandatory gates

A deploy is not done until all three pass. A green build does not mean the feature works end to end; these gates exist so that is checked every time.

**Gate 1, health.** Run the health-check step (`cc-healthcheck.md`).
- If `CC_HEALTH_CHECK_PATH` is configured in the app's env vars, the platform validates natively, and a passing deploy already guarantees health.
- If not, use the external polling loop in the health-check step.

**Gate 2, migrations actually applied** (only when the deploy included migrations). Drizzle prints a success line even when it applied nothing. Run the verification from `cc-migrations.md` ("success message lies"): compare the rows in `drizzle.__drizzle_migrations` with the journal entries, and spot-check one artifact the migration was supposed to create.

**Gate 3, contract smoke.** Exercise ONE real end-to-end path through the feature that shipped (call the new endpoint with real auth, load the page, send the widget message), not just `/health`. If the change has a UI, drive it. If it has an API contract, call it. Report the actual observed response, not the deploy status.

Never report a deploy as successful before every applicable gate has run. If a gate cannot run (for example no production credentials), say so explicitly instead of skipping silently.
