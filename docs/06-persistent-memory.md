# 06. Persistent memory with privacy tiers

**Problem.** Each session starts cold, and a crashed session loses what it learned. Putting everything in one always-loaded file wastes context and mixes private material with working notes.

**Layout** (details and note formats in `memory/README.md`):

| Folder or file | Role |
|---|---|
| `sessions/` | one note per session: what was built, decisions with rationale, files changed, next entry point, open threads |
| `insights/` | one note per non-obvious pattern: pattern, why it matters, where it applies |
| `telos/` | identity tiers, see below |
| `session-checkpoints/` | crash-recovery breadcrumbs, one small JSON per session |
| `digests/` | weekly harness-usage reports |
| `notes/` | human-only space, never written by the agent |
| `RECENT.md`, `INSIGHTS.md` | rebuilt nightly from sessions and insights |

**Privacy tiers (TELOS).** Tier A files are loaded at session start. Tier B files load only when a trigger in the index matches the task. Tier C (`sensitive/`) is read only when the current message explicitly asks, and is gitignored. Each file carries `stability` and `last_reviewed` in its frontmatter, and the review cadence follows from it: stable 90 days, changing 30, volatile 7. `hooks/brain-loaded.sh` reads only that structure and counts, never the content.

**Crash recovery without an LLM call.** `hooks/checkpoint-session.sh` runs at every Stop and writes `{session_id, transcript_path, cwd, task_id, last_active}`. `hooks/session-end.sh` archives the checkpoint only if a session note was written in the last 60 minutes, so a leftover checkpoint means an unfinished session. `hooks/session-start.sh` counts checkpoints older than 2 hours and tells the model to offer recovery once, never to run it unprompted. Recovery is `memory/commands/promote-sessions.md`.

**Nightly and weekly jobs** (`memory/brain-nightly.py`, `memory/brain-digest.py`, `memory/bm-index.py`; stdlib only, `BRAIN_DIR` overrides the location):
- Nightly: rebuild `RECENT.md` and `INSIGHTS.md`, refresh the Basic Memory index if that tool is installed, promote orphaned checkpoints in bounded rounds.
- Weekly: `brain-digest.py` counts sessions, decisions, insights and checkpoints, and scans transcripts for skills, MCP servers and agent types actually used. The digest is the harness's observability. A skill or MCP server with zero calls across four digests is a removal candidate.
- The digest is written to `$BRAIN_DIR/digests/YYYY-Www.md` and also printed to stdout. Nothing pushes it anywhere; you open the file.

**Write-back allowlist.** The agent writes only to `sessions/`, `insights/`, `raw/`, the index, and the processed-checkpoint folder. See `templates/CLAUDE.router.example.md`.

**Limits.** The Basic Memory index depends on that open-source tool at a specific version. Promotion needs the `claude` CLI. The templates in `memory/telos-templates/` are empty on purpose; no notes from a real memory folder are included. Real digests list the tools their owner uses, so they are not shipped either.
