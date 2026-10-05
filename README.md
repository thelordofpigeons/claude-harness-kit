# claude-harness-kit

This repo is a set of parts extracted from a Claude Code setup that I use every day, with everything private removed. It shows how I make agent output controllable: a gate before code, hooks that check work mechanically, review loops with cost limits, an independent evaluator, and file-based memory that survives crashes. It is not a framework and not a plugin. You copy the pieces you want.

Read it in about ten minutes: the status table, the philosophy section below, then one page per mechanism in [docs/](docs/). Each docs page fits on one screen.

## Status

Labels: **IN DAILY USE** means the original of this file runs in my own setup. **TEMPLATE** means the original was tied to an employer process or tool and was rewritten with placeholders; the parameters are listed in the first lines of the file. **WINDOWS-ONLY** needs PowerShell or Windows process APIs. **UNTESTED HERE** means nothing in this repo runs it.

The files in this repo are edited copies. "In daily use" describes the originals; the copies are verified only by the tests named in the last column.

| Component | Status | Verified by |
|---|---|---|
| [hooks/workflow-gate.sh](hooks/workflow-gate.sh) | TEMPLATE | `scripts/selftest.sh` smoke test |
| [hooks/task-gate-reminder.sh](hooks/task-gate-reminder.sh) | TEMPLATE | selftest |
| [hooks/session-start.sh](hooks/session-start.sh) | TEMPLATE | selftest |
| [hooks/brain-loaded.sh](hooks/brain-loaded.sh), [checkpoint-session.sh](hooks/checkpoint-session.sh), [session-end.sh](hooks/session-end.sh) | IN DAILY USE | selftest |
| [hooks/filter-noisy-bash.sh](hooks/filter-noisy-bash.sh) | IN DAILY USE | selftest |
| [hooks/pre-deploy-validate.sh](hooks/pre-deploy-validate.sh), [git-commit-reminder.sh](hooks/git-commit-reminder.sh) | TEMPLATE | selftest |
| [hooks/design-lint-hook.sh](hooks/design-lint-hook.sh) | IN DAILY USE | selftest |
| [hooks/frontend-format.sh](hooks/frontend-format.sh), [frontend-typecheck.sh](hooks/frontend-typecheck.sh) | IN DAILY USE | selftest |
| [hooks/audit-report.mjs](hooks/audit-report.mjs) | IN DAILY USE | selftest |
| [hooks/dev-server-reaper.mjs](hooks/dev-server-reaper.mjs) | IN DAILY USE, WINDOWS-ONLY | selftest does real work only on Windows |
| [scripts/design-lint.mjs](scripts/design-lint.mjs) and [fixtures](scripts/fixtures/) | IN DAILY USE (provenance note in the file header) | selftest: bad fixtures must fail, good must pass |
| [scripts/shot.mjs](scripts/shot.mjs) | IN DAILY USE, UNTESTED HERE | needs Chrome, syntax check only |
| [scripts/task-state.sh](scripts/task-state.sh) | TEMPLATE | selftest |
| [scripts/permissions-secrets-sweep.ps1](scripts/permissions-secrets-sweep.ps1), [branch-divergence-audit.ps1](scripts/branch-divergence-audit.ps1), [harness-audit.ps1](scripts/harness-audit.ps1) | WINDOWS-ONLY, UNTESTED HERE | parsed by selftest when PowerShell exists, never run in CI |
| [statusline/](statusline/) | TEMPLATE | syntax check |
| [workflows/review-until-dry.js](workflows/review-until-dry.js), [design-variants.js](workflows/design-variants.js) | IN DAILY USE, UNTESTED HERE | they run only inside the Workflow runtime; selftest parses them |
| [agents/design-review.md](agents/design-review.md) | IN DAILY USE | none (a prompt) |
| [agents/tracker.md](agents/tracker.md), [agents/ops-agent.md](agents/ops-agent.md) | TEMPLATE, UNTESTED HERE | never run against a live tracker or host in this form |
| [templates/](templates/) (router file, task gate skill, UI protocol skill, status command, hosting examples) | TEMPLATE | none (prompts) |
| [memory/](memory/README.md) scripts and TELOS templates | IN DAILY USE | `memory/tests` (pytest), `memory/telos-check.test.sh` |
| [tools/hygiene/](tools/hygiene/) | written for this repo | `tools/hygiene/tests` (pytest, planted leaks) |

## Philosophy

**1. The gate before code.** Rules written in a router file get skipped under load. So a `UserPromptSubmit` hook classifies each prompt with a regex (imperative verb plus code noun, not a question) and injects an instruction to load the workflow skill, or a resume notice when a task is active. A `PreToolUse` hook on Edit and Write is a second checkpoint with a lock file so it does not nag. The skill itself is four workflows: classify, announce, track, steps. Files: [hooks/workflow-gate.sh](hooks/workflow-gate.sh), [hooks/task-gate-reminder.sh](hooks/task-gate-reminder.sh), [templates/skills/task-gate-workflow](templates/skills/task-gate-workflow/SKILL.md). Page: [docs/01](docs/01-gate-before-code.md).

**2. Model routing and effort tiers.** Every agent call sets a model. Cheap models read files and do mechanical work; the session model is kept for judgement. The working rule is 3 to 4 parallel agents per stage; the scripts do not enforce it (`design-variants` allows up to 5 generators, `review-until-dry` starts one finder per lens and does not cap the lens list). The review workflow takes a `tier` argument that moves finders and verifiers between model and effort levels. Files: [workflows/](workflows/), [agents/tracker.md](agents/tracker.md) (Haiku), [agents/ops-agent.md](agents/ops-agent.md) (Haiku). Page: [docs/02](docs/02-model-routing.md).

**3. Parallel agents with batched verification.** Implementers get disjoint targets so they cannot collide. Generators get opposed aesthetic frames, because divergence comes from the frame and not from asking for creativity. One judge compares the results, and verification is batched, not run per finding. File: [workflows/design-variants.js](workflows/design-variants.js). Page: [docs/03](docs/03-parallel-agents-and-verification.md).

**4. Adversarial review loops with convergence guards.** Finder agents each take one lens, a dedup pass merges semantic duplicates, and verifiers check findings against the files in batches. The loop stops after 2 dry rounds, at `maxRounds`, or at the token budget, whichever comes first. An earlier unbounded version produced mostly duplicate findings at high cost, which is why the ceilings exist. File: [workflows/review-until-dry.js](workflows/review-until-dry.js). Page: [docs/04](docs/04-adversarial-review-loops.md).

**5. Hooks as the enforcement layer.** Three strengths, weakest that works: advisory (print and exit 0), blocking (exit 2 so findings return to the model), and a bounded-retry `Stop` hook (typecheck, at most 2 rounds per session so old type debt cannot trap the agent). Only the design lint blocks outright. The evaluator on top of it is an agent that is never the builder and works from measured screenshots and lint output. Files: [hooks/](hooks/), [scripts/design-lint.mjs](scripts/design-lint.mjs), [agents/design-review.md](agents/design-review.md). Page: [docs/05](docs/05-hooks-as-enforcement.md).

| Hook | Event | Blocking |
|---|---|---|
| design-lint-hook.sh | PostToolUse Edit, Write | yes, on ERROR findings |
| frontend-typecheck.sh | Stop | yes, max 2 rounds |
| all other hooks | various | no |

**6. Persistent memory with privacy tiers.** Session notes, insight notes, and identity files in three tiers (auto-load, load on trigger, explicit ask only). Each identity file has a review cadence by stability: 90, 30 or 7 days. A `Stop` hook writes a small JSON breadcrumb per turn with no model call, so a crashed session can be recovered later. A nightly job rebuilds the summaries. A weekly digest counts which skills, MCP servers and subagents were actually used, and a component with zero use across four digests is a removal candidate. The digest is written to `$BRAIN_DIR/digests/YYYY-Www.md` and printed to stdout; nothing pushes it anywhere. Files: [memory/](memory/README.md). Page: [docs/06](docs/06-persistent-memory.md).

**7. Verification of this repo itself.** The repo was produced by copying, then editing by hand, then scanning. The private denylist is not in the repo: `leak_scan.py` reads it from `--denylist FILE`, `$KIT_DENYLIST`, or `~/.config/claude-harness-kit/denylist.txt`. Without one, rule R1 is skipped, and `check_all.sh --strict` fails by design, so a fresh clone passes `check_all.sh` but not `--strict`. [tools/hygiene/](tools/hygiene/) has a leak scanner (paths, emails, tracker and platform IDs, private network addresses, secret shapes, credential-reading code, dated strings, and a private denylist that is never committed), a text scanner (dashes, emoji, byte order marks, carriage returns, size), and tests that plant each kind of leak at runtime and check that the scanners fail on it and pass on clean text. `tools/hygiene/check_all.sh` runs everything; add `--strict` when you have a denylist.

## Quick start

0. Requirements: bash, git, and node (most hooks parse their JSON input with node, so the gate hook does nothing without it). Python 3.9 or newer is needed only for `memory/` and `tools/hygiene/`; use `python3` where `python` does not exist. `timeout` is optional (macOS lacks it; the typecheck hook then runs tsc without a time limit).
1. Install the files under `~/.claude/` (the paths the scripts and `settings.example.json` expect):
   ```bash
   mkdir -p ~/.claude/{hooks,scripts,agents,workflows,skills,commands}
   cp hooks/* ~/.claude/hooks/
   cp scripts/*.sh scripts/*.mjs scripts/*.ps1 ~/.claude/scripts/
   cp statusline/statusline.* ~/.claude/
   cp agents/*.md ~/.claude/agents/
   cp workflows/*.js ~/.claude/workflows/
   cp -r templates/skills/* ~/.claude/skills/
   cp templates/commands/*.md ~/.claude/commands/
   ```
   The `agents/` and `templates/` files contain placeholders; edit them before use. `design-variants.js` finds the screenshot tool at `~/.claude/scripts/shot.mjs`; pass the `shotScript` argument to use another path.
2. Merge the entries you want from [settings.example.json](settings.example.json) into your real settings file by hand. JSON has no comments, so notes are in [docs/05](docs/05-hooks-as-enforcement.md). Keep line endings LF; a CRLF settings file can break hook commands on Windows.
3. Set the parameters you need: `WORKFLOW_SKILL`, `TRACKER_AGENT`, `TRACKER_UPDATE_CMD`, `HARNESS_TASK_FILE`, `BRAIN_DIR`, `CLAUDE_DIR`, `CLAUDE_HOME`, `KIT_REPOS_ROOT`, `DEPLOY_CMD_REGEX`. Each has a default described in the header of the file that reads it, except `KIT_REPOS_ROOT` (used only by `branch-divergence-audit.ps1`), which has no default: the audit skips itself when it is unset.
4. Run `bash scripts/selftest.sh`, then `bash tools/hygiene/check_all.sh`.
5. For memory, follow [memory/README.md](memory/README.md).

The scripts run as `bash hooks/x.sh`; the executable bit is not required.

## Windows notes

- Windows-only files: `hooks/dev-server-reaper.mjs` and the three `.ps1` audits in `scripts/`, plus `memory/telos-check.ps1`.
- The shell hooks assume Git Bash. Lock files under `/tmp` are a Git Bash convention and will behave differently under WSL or native Linux paths.
- `shot.mjs` looks for Chrome in a list of usual install locations.

## What was removed and why

Categories only: employer process and tracker IDs, client and project material, employer branding, personal items, third-party authored skills and commands (excluded whenever provenance was unclear), credential-handling code (the status line's usage-limits block was deleted, not hidden behind a flag), a personal diagnostics script, a notification hook that writes to the registry, and all memory content. See [docs/07](docs/07-what-was-removed.md). The real harness has more than is shown here, and the unlisted items were left out on purpose.

## Honest limits

- The Basic Memory index refresh depends on that open-source tool at a specific version (0.23 per the script comments). Everything else in `memory/` works without it.
- Promotion of crashed sessions needs the `claude` CLI and the shipped `promote-sessions` command.
- The workflows need the Workflow runtime. Outside it they only parse.
- The templates have never run against a live tracker or hosting account in this form.
- There are no benchmarks and no cost claims beyond what comments in the files state.
- The hook smoke tests feed fabricated JSON on stdin. They do not prove behavior inside every Claude Code version.
- The scanners find patterns. Reading every copied file was the main control, and the scanners are the second.

## License

MIT, see [LICENSE](LICENSE). No third-party skills, commands or plugins are included. The design lint and the design-review agent implement generic front-end checks written for this kit; the lint's header says that third-party design checklists influenced which checks were automated, that nothing was copied from them, and that their licenses were not checked.
