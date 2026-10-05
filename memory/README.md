# memory: a file-based memory scaffold for Claude Code

Plain markdown plus a few stdlib Python scripts and four hooks. The agent reads a small, tiered set of files at session start, writes a session note at session end, and a nightly job rebuilds the summaries. The design reasoning is in [../docs/06-persistent-memory.md](../docs/06-persistent-memory.md). This page covers layout, note formats, scheduling and tests.

Nothing in this folder contains real notes. The templates are empty and the two examples are invented.

## Layout of a memory folder

The memory folder is `$BRAIN_DIR`, default `~/brain`. Every script and hook honors that variable.

```
$BRAIN_DIR/
  sessions/             one note per session, YYYY-MM-DD-HH.md (agent writes)
  insights/             one note per non-obvious pattern, YYYY-MM-DD-slug.md (agent writes)
  telos/                identity tiers A/B/C (user owns; agent edits only on explicit review)
    sensitive/          Tier C, optional, gitignored
  raw/                  dropped source material (agent may write)
  session-checkpoints/  crash-recovery JSON, one per session (Stop hook writes)
    processed/          archived checkpoints (SessionEnd hook and /promote-sessions move them here)
  digests/              weekly reports from brain-digest.py
  logs/                 nightly logs
  notes/                human-only space, the agent never writes here
  _INDEX.md             agent-regenerated overview (projects, decisions, open threads)
  RECENT.md             rebuilt nightly from the last 7 days of sessions
  INSIGHTS.md           rebuilt nightly, one entry per insight
```

Write-back allowlist for the agent: `sessions/`, `insights/`, `raw/`, `_INDEX.md`, `session-checkpoints/processed/`. The scripts additionally own `RECENT.md`, `INSIGHTS.md`, `digests/` and `logs/`. Never `notes/`, and `telos/` only when the user asks for a review. The same rule is spelled out in [../templates/CLAUDE.router.example.md](../templates/CLAUDE.router.example.md).

## What is in this folder

| Path | What it is |
|---|---|
| `brain-nightly.py` | Rebuilds `RECENT.md` and `INSIGHTS.md`, refreshes the Basic Memory index, promotes orphaned checkpoints in at most 5 headless rounds |
| `brain-digest.py` | Weekly digest: notes written, decisions, checkpoints, and which skills, MCP servers and subagents transcripts show in use |
| `bm-index.py` | Headless Basic Memory index refresh (see limits) |
| `telos-templates/` | Ten empty identity files with the required frontmatter, plus a `.gitignore` for `sensitive/` |
| `telos-check.ps1`, `telos-check.test.sh` | Validator (PowerShell) and a test that runs it against a temporary copy |
| `commands/promote-sessions.md` | Crash recovery: turns old checkpoints into session notes via a Haiku subagent |
| `commands/promote-insights.md` | Monthly distillation: recurring insights become patterns, deterministic ones become hook candidates |
| `skills/recall/SKILL.md` | Read path: search the notes, answer with dates and wikilinks |
| `examples/` | One invented session note and one invented insight, using the real formats |
| `tests/test_brain.py` | pytest suite against a fabricated memory folder |

Hooks that belong to this scaffold live in `../hooks/`: `checkpoint-session.sh` (Stop), `session-end.sh` (SessionEnd), `session-start.sh` (UserPromptSubmit), `brain-loaded.sh` (SessionStart).

## Note formats

Session note (`sessions/YYYY-MM-DD-HH.md`), see [examples/session-2025-01-15-09.md](examples/session-2025-01-15-09.md):

```
---
type: session
date: YYYY-MM-DD
task_id: <tracker id or none>
permalink: brain/sessions/YYYY-MM-DD-HH
---
## What we built            named files and functions
## Decisions made (with rationale)     "Decision, because reason"
## Files changed            exact paths
## Next session entry point "Continue at file:line, what to do" or "No active work"
## Open threads
```

Insight note (`insights/YYYY-MM-DD-slug.md`), see [examples/insight-2025-01-15-example.md](examples/insight-2025-01-15-example.md):

```
---
type: insight
topic: <kebab-slug>
project: <name>
confidence: high|medium|low
permalink: brain/insights/YYYY-MM-DD-slug
---
## Pattern / Decision
## Why it matters
## Applies to
```

TELOS file (`telos/NN-name.md`): frontmatter `telos_section`, `sensitivity` (public or sensitive), `stability` (stable, changing, volatile), `last_reviewed` (YYYY-MM-DD), `permalink`. Review cadence by stability: stable 90 days, changing 30, volatile 7. Tier A (index, identity, context, preferences) loads at session start, Tier B loads when a trigger in `00-index.md` matches, Tier C (`sensitive/`) is read only when the current message asks for it.

The templates ship with `last_reviewed: 2025-01-01` so the date is valid ISO. That date is now past every cadence, so a fresh install will report every file as overdue until you set `last_reviewed` to today in each file you fill in. That is intended: an unreviewed template should look unreviewed.

Checkpoint (`session-checkpoints/<session_id>.json`), written by `checkpoint-session.sh` after every turn with no model call:

```
{"session_id": "...", "transcript_path": "...", "cwd": "...", "task_id": "...", "last_active": "2025-01-15T09:00:00Z"}
```

A checkpoint whose `last_active` is more than 2 hours old and which was not archived by `session-end.sh` counts as an orphan.

## Setup

```bash
export BRAIN_DIR="$HOME/brain"            # optional, this is the default
mkdir -p "$BRAIN_DIR"/{sessions,insights,raw,session-checkpoints/processed,digests,logs,notes}
cp -r memory/telos-templates "$BRAIN_DIR/telos"
cp memory/telos-check.ps1 "$BRAIN_DIR/telos/"
printf 'telos/sensitive/\n' >> "$BRAIN_DIR/.gitignore"      # if the folder is a git repo
mkdir -p ~/.claude/commands
cp memory/commands/*.md ~/.claude/commands/
mkdir -p ~/.claude/skills/recall && cp memory/skills/recall/SKILL.md ~/.claude/skills/recall/
```

Then wire the four hooks from `settings.example.json` and add the session start and end steps to your router file. Commands are written as `python`; use `python3` if that is all your system has. Run `python memory/brain-nightly.py --no-promote --no-sync` once to see `RECENT.md` and `INSIGHTS.md` appear.

## Scheduling

The scripts are plain commands, so any scheduler works. The names below are examples.

Windows Task Scheduler:

```
schtasks /Create /TN HarnessBrainNightly /SC DAILY /ST 03:30 /TR "python %USERPROFILE%\harness\memory\brain-nightly.py"
schtasks /Create /TN HarnessBrainWeeklyDigest /SC WEEKLY /D MON /ST 08:30 /TR "python %USERPROFILE%\harness\memory\brain-digest.py"
```

cron:

```
30 3 * * *  BRAIN_DIR="$HOME/brain" python3 "$HOME/harness/memory/brain-nightly.py"
30 8 * * 1  BRAIN_DIR="$HOME/brain" python3 "$HOME/harness/memory/brain-digest.py"
```

Nightly steps, in order: rebuild `RECENT.md` (open threads and decisions from the last 7 days, deduplicated, at most 10 each); rebuild `INSIGHTS.md` (one block per insight, with the first line of its pattern); refresh the Basic Memory index if `basic-memory` is on the PATH; if orphaned checkpoints exist, run `claude -p /promote-sessions --model haiku --permission-mode acceptEdits` up to 5 times and stop at the first round that makes no progress. Flags: `--no-promote`, `--no-sync`. Output goes to `$BRAIN_DIR/logs/nightly-YYYY-MM-DD.log`.

## Where the digest lands

`brain-digest.py` writes the weekly digest to `$BRAIN_DIR/digests/YYYY-Www.md` (ISO year and week, for example `2025-W03.md`) and prints the same body to stdout. Nothing pushes it anywhere: you open the file, or read the scheduler's captured output. `--days N` changes the window (default 7).

The digest reads full transcripts under `$CLAUDE_DIR/projects` (default `~/.claude/projects`) and lists the skills, MCP servers and subagents it finds. A real digest therefore describes your private tooling. Do not publish one, and do not commit `digests/` to a public repo.

The rule it exists to enforce: a skill or MCP server with zero calls for four consecutive digests is a removal candidate.

## Tests

```bash
python -m pytest memory/tests -q          # parsers, nightly rebuild, orphan count, TELOS cadence, digest, index counts
bash memory/telos-check.test.sh           # validator against a temporary copy of the templates (needs PowerShell)
```

`tests/test_brain.py` builds a memory folder from fabricated fixtures in a pytest tmp dir, points `HOME`, `USERPROFILE`, `BRAIN_DIR` and `CLAUDE_DIR` at it, and patches `pathlib.Path` reads so that any access to the real `~/brain` fails the test. One test proves the guard trips.

The tests found one parser bug in the original scripts, now fixed: an empty `## Decisions` section made the regex run on and swallow the next section, so open threads were reported as decisions.

## Honest limits

- `bm-index.py` and the index refresh depend on the open-source Basic Memory tool, written against version 0.23 (the SQLite layout and the lack of a CLI sync command are version specific). Without it, everything else still works; `recall` falls back to ripgrep.
- Promotion needs the `claude` CLI on the PATH and the `commands/promote-sessions.md` command installed.
- The scripts are tested on Windows with Git Bash. The shell hooks use `/tmp` lock files, a Git Bash convention.
- `telos-check.ps1` needs PowerShell; the cadence and required-key checks are not duplicated in Python.
- The scheduled jobs are not run by any CI here. The pytest suite covers the functions they call, not the scheduler.
- `brain-digest.py` counts what it can see in transcript JSON. If the transcript format changes, the counts drop to zero rather than failing loudly.
