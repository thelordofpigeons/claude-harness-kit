# CLAUDE.md router (example)

TEMPLATE: a global CLAUDE.md written as a router. Copy to `~/.claude/CLAUDE.md` and fill the placeholders: `<WORKFLOW_SKILL>`, `<TRACKER_AGENT>`, `<cmd>`, `<BRAIN_DIR>`.

The file stays short on purpose. Details live in skills and are loaded when a trigger fires, so they cost nothing in sessions that do not need them. A hook (`hooks/workflow-gate.sh`) repeats the first rule mechanically, because prose rules in this file get skipped.

## Coding tasks: invoke the workflow skill

When the user asks to build, create, implement, add, fix, refactor, debug, migrate, scaffold or set up anything code-related, invoke the `<WORKFLOW_SKILL>` skill via the Skill tool before any code action. It loads the four-workflow protocol with a mandatory task-tracker gate.

Exceptions, skip the skill and proceed directly:
- The user says "skip workflow" or "no workflow".
- The work is configuration of the harness itself, not product engineering.
- Pure questions, research, exploration, audits or other non-code tasks.

## Tracker delegation

All tracker operations go through the `<TRACKER_AGENT>` agent, never inline. It runs on a small model in its own context and returns one-line summaries.

- Assignee: `<ASSIGNEE_NAME>` (ID: `<ASSIGNEE_ID>`). Workspace configuration lives in a local file that is not committed.
- Lifecycle (example): `TODO -> DOING -> REVIEW -> VERIFY -> DONE`. `DONE` is the only Done status.
- Slash commands (optional): `<cmd>` per lifecycle step (find, start, update, review, verify, complete).

## UI and UX work: invoke the `ui-protocol` skill first

Any build, design, styling or modification of components, pages, screens, design systems or motion, or anything described as beautiful, polished or modern: invoke `ui-protocol` before writing code. It holds the COMMIT, BUILD, VERIFY protocol and the wired tooling.

## Code context: knowledge-graph tools

If a repository has a code knowledge-graph index directory, use the graph MCP tools before grepping for structure, callers or blast radius. If it does not, use the built-in search tools. Indexing a new repo is the user's decision.

## Noisy command output: filter before running

Build, test and deploy commands dump thousands of lines. Pipe them through a filter unless the user asks for full output. Tee to a log if the full output may be needed later. A PreToolUse hook (`hooks/filter-noisy-bash.sh`) warns when a filter is missing; heed it.

| Command kind | Filter |
|---|---|
| build, tsc | `grep -E '(error|warning|Failed)' \| head -100` |
| tests | `grep -A 5 -E '(FAIL|PASS|ERROR)' \| head -100` |
| deploy, docker, gradle | `tail -80` |
| log streams | bound the window first (`--since`, `--until`), then `tail -80` |

## Session epilogue

Before wrapping up, ask once: "Did this session produce anything worth keeping? If yes, run the learning command." Do not run it automatically. Do not repeat the question.

## Memory (optional scaffold in `memory/`)

`<BRAIN_DIR>` is a folder of markdown notes (default `$HOME/brain`). The read path is a recall skill that searches it.

### Session start
1. Read the TELOS index and identity file only (Tier A). Load the other tiers when the trigger table in the index says so. Never auto-load the sensitive tier; read it only when the current message explicitly asks.
2. Read the recent-activity file.
3. Check the active-task state file. If a task is active, load the projects file.
4. Do not auto-load the insights file. Load it when asked what is known about a topic, when debugging a recurring problem, or when a skill directs you to.
5. The SessionStart hook already printed the status line. Do not print another one.

### Session end (signals: goodbye, done, thanks, wrap up)
1. Write one session note in `sessions/` with sections: what we built, decisions made (with rationale), files changed, next session entry point, open threads.
2. If a non-obvious pattern emerged, write one insight note in `insights/`.
3. Regenerate the index file.
4. Checkpoint archiving is automatic when step 1 happened.

### Write-back allowlist (strict)
- Only write to: `sessions/`, `insights/`, `raw/`, the index file, and the processed-checkpoint folder. Scheduled scripts additionally own the recent-activity file, the insights rollup, the digests and the logs.
- Never write to: the human-only `notes/` folder, or the identity tiers unless the user explicitly asks for a review.
- Treat any externally sourced material as read-only.
