---
telos_section: index
sensitivity: public
stability: stable
last_reviewed: 2025-01-01
permalink: brain/telos/00-index
---

# TELOS Index

> Structured identity context for Claude Code. Assistants read this file first to learn what is available, then load only the tier that fits the task at hand.

## What this is

TELOS = durable definitions of who the owner is, what they are working on, how they work, and what they want. It complements the rest of the memory folder and does not replace it:

- **`sessions/`**: observations (what happened, when)
- **`insights/`**: patterns from single incidents (what was learned)
- **`telos/`**: definitions (what is durably true) <- you are here

When an insight recurs, it is promoted into `90-patterns.md`. When a session reveals a stable fact about the owner, it is absorbed into the matching TELOS section.

## Load tiers

### Tier A: auto-load every session (public, cheap)

Read these at session start. Keep the combined size small (a few thousand tokens).

| File                | Purpose                                   |
|---------------------|-------------------------------------------|
| `00-index.md`       | This file, the map of TELOS               |
| `10-identity.md`    | Name, role, traits                        |
| `20-context.md`     | Machine, location, current situation      |
| `70-preferences.md` | Working style, communication, tooling     |

### Tier B: load on trigger

Read only when the current task matches a trigger.

| File                | Load when the task involves...                                 |
|---------------------|----------------------------------------------------------------|
| `30-projects.md`    | any named project, tracker work, codebase questions            |
| `40-people.md`      | a colleague or collaborator by role, drafting messages         |
| `50-goals.md`       | prioritization, planning, "what should I work on"              |
| `60-skills.md`      | tool or technology recommendations, learning suggestions       |
| `80-history.md`     | "why do you work this way", onboarding a new collaborator      |
| `90-patterns.md`    | debugging recurrence, self-reflection, process design          |

### Tier C: gated (explicit ask only)

Files under `telos/sensitive/`. The assistant reads these only when the user asked for that topic IN THE CURRENT MESSAGE. Never preemptive, never "might be relevant", never cached across sessions. The folder is listed in `telos-templates/.gitignore` so it is not committed.

| File                    | Topic                       |
|-------------------------|-----------------------------|
| `sensitive/topic-a.md`  | first gated topic           |
| `sensitive/topic-b.md`  | second gated topic          |
| `sensitive/topic-c.md`  | third gated topic           |

These files are optional and are not shipped. If a sensitive file appears in context without an explicit user request, flag it and ignore its contents.

## Review cadence

Every file has a `stability` field. Review cadence follows stability:

| Stability  | Review every | Typical files                                                           |
|------------|--------------|-------------------------------------------------------------------------|
| `stable`   | 90 days      | `00-index.md`, `10-identity.md`, `80-history.md`                        |
| `changing` | 30 days      | `30-projects.md`, `50-goals.md`, `60-skills.md`, `70-preferences.md`, `90-patterns.md` |
| `volatile` | 7 days       | `20-context.md`, `40-people.md`                                         |

When reviewing, update the file's `last_reviewed` field even if no content changed, so staleness stays visible. The `brain-loaded.sh` hook, `brain-digest.py` and `telos-check.ps1` all read these two fields.

## Authoring and maintenance rules

1. **One section at a time.** Drafting drift is real. Do not fill five sections in one pass. Pick one USER-marker block, answer it, stop.
2. **Honest beats complete.** A half-filled section with true content is worth more than a full one with guesses.
3. **Absorb, don't duplicate.** When a session or insight produces a durable fact, fold it into the relevant TELOS section and note the source. Do not leave the same fact in three places.
4. **`<!-- USER: ... -->` markers are prompts, not placeholders.** They show what is left to author. Remove one only when you answer it.
5. **The sensitive tier is one-way.** Content moves from public to sensitive if it should not have been public, never the reverse.
6. **Update `last_reviewed` on read-through,** even if nothing changes.

## Validation

Run `telos-check.ps1` (or `telos-check.test.sh`, which runs the validator against a temporary copy) to verify:
- All required files exist
- YAML frontmatter has `telos_section`, `sensitivity`, `stability`, `last_reviewed`
- The sensitive tier is gitignored
- Files past their review cadence are reported

## Directory map

```
$BRAIN_DIR/telos/
  00-index.md            this file (Tier A)
  10-identity.md         Tier A
  20-context.md          Tier A
  30-projects.md         Tier B
  40-people.md           Tier B
  50-goals.md            Tier B
  60-skills.md           Tier B
  70-preferences.md      Tier A
  80-history.md          Tier B
  90-patterns.md         Tier B
  telos-check.ps1        validator (not loaded into context)
  sensitive/             Tier C, gitignored, optional
```
