---
name: cc-healthcheck
description: Verify a Clever Cloud app is healthy after deployment. Covers the native health-check path, an external polling fallback, deploy lifecycle stages, log-based triage, and the failure resolution path.
---

TEMPLATE: Clever Cloud is used here as one labeled example. The idea carries over to any platform: deploy-end is not healthy, so verify health separately and bound every log query.
Parameters: `<APP_ID>`, `<APP_HOST>`, `API_APP_ID`, `DASHBOARD_APP_ID`. Flattened from a skill directory; to use it, save it as `skills/cc-healthcheck/SKILL.md`.

# Clever Cloud health check

## Deploy lifecycle

```
push -> build (CC_PRE_BUILD_HOOK) -> post-build (CC_POST_BUILD_HOOK) -> run (CC_PRE_RUN_HOOK) -> start -> [health check]
```

**Critical:** `clever deploy` exits at deploy-end (build and deploy stream finished). The app may still be starting, migrating or crashing. "Deploy succeeded" is not the same as "app is healthy".

---

## Primary: CC_HEALTH_CHECK_PATH (native)

```bash
# Set in the console: App, Environment variables (test AND prod)
CC_HEALTH_CHECK_PATH=/health
```

- The platform polls this endpoint during deployment.
- A non-2xx response fails the deployment and the old instance keeps serving (zero downtime).
- A passing deploy with this configured means app health is guaranteed.
- Recommended response: `{ "status": "ok", "version": "x.y.z" }`

Configure this first. The external polling below is a fallback for apps without it.

---

## Fallback: external polling (60 second timeout)

```bash
APP_URL="https://<APP_HOST>"
for i in $(seq 1 12); do
  HTTP=$(curl -s -o /dev/null -w "%{http_code}" "$APP_URL/health")
  if [ "$HTTP" = "200" ]; then
    echo "App healthy (attempt $i)"
    exit 0
  fi
  echo "Attempt $i: HTTP $HTTP, waiting 5s"
  sleep 5
done
echo "Health check FAILED after 60s"
exit 1
```

---

## Log-based check

```bash
# Snapshot. ALWAYS bound the window with --until. clever logs streams
# continuously and never closes the pipe; without --until, tail waits for
# an EOF that never comes and the command hangs with zero output.
clever logs --app <APP_ID> --since 2h --until 5s | tail -80

# Errors only
clever logs --app <APP_ID> --since 30m --until 5s | grep -i error | tail -40

# Belt-and-braces variant if --until is ever unavailable
timeout 30 clever logs --app <APP_ID> --since 2h | tail -80
```

**Duration format:** always use a unit suffix (`30m`, `2h`, `600s`). A bare number (`--since 300`) silently live-streams from now instead of fetching history, despite what `--help` suggests. Invalid values (`5x`) are also silently accepted as live-stream-only.

---

## Failure triage path

1. **Check the health-path response.** What HTTP status is it returning?
2. **Check the deploy trigger:** `clever activity --app <APP_ID> | tail -3`. A restart triggered by a monitoring "unreachable" event (instead of your push or the console) means the platform's monitor killed the instance because health checks timed out, typically because heavy in-process work starved the event loop. Any background task running at that moment died mid-flight.
3. **Check logs:** `clever logs --app <APP_ID> --since 2h --until 5s | tail -80`
4. **Check migration status:** did `CC_PRE_RUN_HOOK` complete? Any migration errors in the logs?
5. **Check env vars:** `clever env | grep -E "(DATABASE|REDIS|PORT)"`. Any required variable missing?
6. **Check the console Activity view** for deployment events and error messages.

**Post-mortem on an ended deploy.** `clever logs` works retroactively with explicit bounds: pass `--since` and `--until` as ISO-8601 timestamps with an explicit offset to retrieve logs from a window that is already over.

---

## Multi-app health matrix

When a project has several apps, check all of them after deployment. Keep app IDs and URLs in the project's `CLAUDE.md`, then:

```bash
for APP_ID in $API_APP_ID $DASHBOARD_APP_ID; do
  echo "=== $APP_ID ==="
  clever status --app $APP_ID
done
```
