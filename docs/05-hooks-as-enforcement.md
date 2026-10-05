# 05. Hooks as the enforcement layer

**Problem.** Instructions in prompts and skills are requests. A hook is code the harness runs whether or not the model remembers the instruction. The kit uses hooks at three strengths, and picks the weakest one that works.

| Strength | Meaning | Example |
|---|---|---|
| Advisory | Prints to the model's context or stderr, always exits 0 | `hooks/filter-noisy-bash.sh`, `hooks/pre-deploy-validate.sh` |
| Blocking | Exits 2 so the findings come back to the model as an error it must act on | `hooks/design-lint-hook.sh` |
| Bounded retry | Blocks a Stop with a JSON decision, with a hard cap on rounds | `hooks/frontend-typecheck.sh` (2 rounds per session) |

**Hook table.**

| Hook | Event | Blocking? | Why it exists |
|---|---|---|---|
| `workflow-gate.sh` | UserPromptSubmit | no | nudges the workflow skill on code requests ([01](01-gate-before-code.md)) |
| `session-start.sh` | UserPromptSubmit, first prompt of the day | no | prints the active task, counts crashed-session checkpoints |
| `brain-loaded.sh` | SessionStart | no | one status line: last session, open threads, overdue memory files |
| `audit-report.mjs` | SessionStart | no | surfaces a scheduled audit result once, using an mtime marker |
| `task-gate-reminder.sh` | PreToolUse Edit, Write | no | second enforcement point for the task gate |
| `filter-noisy-bash.sh` | PreToolUse Bash | no | warns when a build, test or deploy command has no output filter |
| `pre-deploy-validate.sh` | PreToolUse Bash | no | warns before a deploy: dirty tree, journal without SQL, diverged main, wrong branch |
| `git-commit-reminder.sh` | PostToolUse Bash | no | after a commit, reminds the agent to update the tracker |
| `design-lint-hook.sh` | PostToolUse Edit, Write | **yes, on ERROR** | the one hard mechanical gate on UI output; WARN stays advisory |
| `frontend-format.sh` | PostToolUse Edit, Write | no | runs the project's own prettier and eslint on the edited file, records touched roots |
| `frontend-typecheck.sh` | Stop | **yes, max 2 rounds** | runs `tsc --noEmit` once per touched project |
| `checkpoint-session.sh` | Stop | no | writes a small JSON breadcrumb, no LLM call |
| `session-end.sh` | SessionEnd | no | archives the checkpoint if a session note was written |
| `dev-server-reaper.mjs` | SessionEnd, Windows only | no | kills dev-server process trees the session left behind |

**Why the typecheck is capped.** A project with old type debt would trap the agent in a stop-fix-stop loop. The hook counts rounds per session and honors `stop_hook_active`, then lets the stop through.

**Why only the design lint blocks.** Prose design gates get skipped, so one rule set is made mechanical: banned fonts, raw hex in components, `transition: all`, and a few others (`scripts/design-lint.mjs`, zero dependencies, with good and bad fixtures in `scripts/fixtures/` as a self-test). The evaluator on top of it is an agent that is never the builder (`agents/design-review.md`).

**Shared conventions.**
- Hooks read their JSON payload from stdin. Most shell hooks parse it with `node`, which makes node a hard dependency; `frontend-format.sh` and `frontend-typecheck.sh` pull a few fields out with `grep` and `sed`, and `pre-deploy-validate.sh` uses `jq` when it is installed and falls back to `grep`.
- State lives under `~/.claude/state` and `~/.claude/current-task*`; checkpoints under the memory folder.
- The shell hooks assume Git Bash on Windows. `/tmp` lock files are a Git Bash convention.

**Wiring.** `settings.example.json` shows events, matchers and timeouts (frontend-typecheck 180 seconds, dev-server-reaper 30). JSON has no comments, so the notes live here: edit your real settings file by hand, merge only the entries you want, and keep line endings LF. A settings file saved with CRLF can break hook commands.

**Limits.** The hooks are tested by `scripts/selftest.sh` with fabricated stdin payloads in a temporary HOME. They have not been run against every shell or OS.
