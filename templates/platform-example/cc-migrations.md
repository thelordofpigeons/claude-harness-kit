---
name: cc-migrations
description: Run database migrations safely on Clever Cloud. Covers correct hook placement (pre-run hook, not pre-build hook), the Drizzle journal append-only rule, a one-shot task-app isolation pattern, rollback options, and ORM equivalents.
---

TEMPLATE: Clever Cloud and Drizzle are used here as labeled examples. The rules (run migrations after dependencies exist, make them idempotent or isolated, verify that they applied) carry over to other platforms and ORMs.
Parameters: `<APP_ID>`, `<ORG>`, `<table>`, `MIGRATION_APP_ID`, `API_APP_ID`. Flattened from a skill directory; to use it, save it as `skills/cc-migrations/SKILL.md`.

# Clever Cloud migrations

## Hook placement (critical)

| Hook | When it fires | Has node_modules? | Use for migrations? |
|---|---|---|---|
| `CC_PRE_BUILD_HOOK` | Before dependency install | **No** | **Never** |
| `CC_POST_BUILD_HOOK` | After build, before cache | Yes | Rarely |
| `CC_PRE_RUN_HOOK` | After build and cache, before app start | **Yes** | **Always** |

```bash
# Set in the console: App, Environment variables
CC_PRE_RUN_HOOK=npm run db:migrate
```

**Why not the pre-build hook?** It fires before `npm install`. There is no `node_modules`, no ORM binary, and the migration fails with "Cannot find module".

Both hooks fail the deployment on a non-zero exit.

---

## Horizontal scaling gotcha

`CC_PRE_RUN_HOOK` runs on every instance when scaling horizontally (3 instances means 3 parallel migration runs).

**Fix:** make all migrations idempotent (`IF NOT EXISTS`, upsert patterns), or use the task-app isolation pattern below.

---

## Task-app isolation pattern (cleanest)

Create a dedicated migration app:

1. Set `CC_TASK=true` in the app's env vars.
2. Set `CC_RUN_COMMAND=npm run db:migrate`.
3. The app runs the command once and terminates, with no persistent instance cost.

Deploy this task app before the main app in CI. `clever deploy` blocks until deploy-end, so the migration completes before the next step runs:

```yaml
env:
  CLEVER_TOKEN: ${{ secrets.CLEVER_TOKEN }}
  CLEVER_SECRET: ${{ secrets.CLEVER_SECRET }}

steps:
  - name: Run migrations
    run: clever deploy -f --app $MIGRATION_APP_ID

  - name: Deploy API
    run: clever deploy -f --app $API_APP_ID
```

Ideal for multi-step migrations, long-running migrations, and strict migration control.

---

## Drizzle journal regression

**Symptom:** migrations are silently skipped, and deployed code expects columns that do not exist in the database.

**Root cause:** `_journal.json` entries had their `"when"` timestamps modified, so Drizzle skips them. Mechanically, the migrator only applies entries whose `when` is greater than the newest `created_at` in `__drizzle_migrations`. Any out-of-order `when` is treated as already applied, with no hash check.

**Rule: the journal is append-only.**
- Never edit existing `"when"` values.
- Never reorder entries.
- Never delete entries.
- Only append new entries at the end.

**Recovery for a stuck entry** (hand-edited or rewritten journal): bump its `when` to a value strictly greater than `MAX(created_at)` in `__drizzle_migrations`. The SQL file does not need to change.

Add a migrations check to CI. It should verify journal and SQL consistency, `when` monotonicity, breakpoint-token hygiene, absence of `DO $$` blocks, and isolation of `ALTER TYPE ADD VALUE` segments, all before deploy. `hooks/pre-deploy-validate.sh` implements the journal and SQL consistency part as an advisory local check.

---

## The success message lies: verify every apply

The "migrations applied successfully" line means the migrator function returned, not that the database changed. There are three documented ways it prints success while doing nothing: a stale `when` (above), an out-of-sync tracking table, and an in-transaction rollback (below). After every migrate:

```sql
-- 1. The row count must match the journal entry count
SELECT COUNT(*) FROM drizzle.__drizzle_migrations;
-- 2. Spot-check an artifact the migration was supposed to create
SELECT column_name FROM information_schema.columns WHERE table_name = '<table>';
```

**Tracking-table trap.** If the schema was originally bootstrapped outside Drizzle (raw SQL, dump and restore), `__drizzle_migrations` is empty. Drizzle then re-runs migration 0000, hits "table already exists", rolls everything back, and exits 0. Bootstrap the tracking table (insert rows for the pre-applied migrations) before Drizzle can ever apply cleanly.

---

## Migration authoring rules (transaction and splitter traps)

1. **One DDL statement per `statement-breakpoint` marker.** A file without breakpoints runs as a single transaction. If any statement cannot run in a transaction (`ALTER TYPE ... ADD VALUE`), everything rolls back, while still printing success.
2. **No `DO $$ ... END $$` blocks.** The splitter cuts on every semicolon and tears dollar-quoted bodies into invalid fragments. Move conditional logic to application code.
3. **Never write the literal breakpoint token in comments.** The splitter is comment-blind and splits there too, producing garbage fragments and a generic "pre-run hook failed" error.

---

## Rollback (fastest first)

1. `clever restart --commit <short-sha>`: redeploy a previous commit, no git history change.
2. Console, Activity view, rollback button (same effect, UI-based).
3. `git revert` followed by `clever deploy -f`: safest for complex multi-file rollbacks.

---

## ORM-specific

| ORM | `CC_PRE_RUN_HOOK` value |
|---|---|
| Drizzle | `npx drizzle-kit migrate` or `npm run db:migrate` |
| Prisma | `npx prisma migrate deploy` |
| Alembic | `alembic upgrade head` |

---

## Manual migration (emergency)

```bash
# Find the database connection string. Postgres add-ons inject
# POSTGRESQL_ADDON_URI by default; DATABASE_URL exists only if aliased.
clever env | grep -E "(DATABASE_URL|POSTGRESQL_ADDON_URI)"

# Run locally against that database
DATABASE_URL="postgresql://<user>:<password>@<host>/<db>" npm run db:migrate
```
