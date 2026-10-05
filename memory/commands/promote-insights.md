# /promote-insights: distillation pass (insights -> patterns -> harness)

Capture is easy and promotion is where pipelines die. This command sweeps recent insights, promotes recurring ones into TELOS, and flags deterministic ones for conversion into hooks or CI checks.

`<BRAIN_DIR>` means the memory folder: the `BRAIN_DIR` environment variable, default `~/brain`.

## Procedure

1. **Scope the sweep.** Read the frontmatter of `<BRAIN_DIR>/telos/90-patterns.md` and take its `last_reviewed`. The sweep covers every file in `<BRAIN_DIR>/insights/` dated after that. If there are more than 40 files, process newest first in batches and say so.

2. **Cluster the swept insights** by theme (for example: deployment, model behavior, process, infrastructure, one named project). For each cluster report the count, the projects touched, and whether the same lesson appears at least twice.

3. **Promote, following the TELOS rule "absorb, don't duplicate":**
   - Any lesson appearing **2 or more times**: draft a concise entry for `90-patterns.md` (failure patterns or success patterns section), citing the source insight files as `[[wikilinks]]`.
   - Any durable fact about how the user works: propose the matching TELOS section instead.
   - Show all drafted entries to the user **before writing**. On approval, write them and update `last_reviewed` in the frontmatter.

4. **Flag automation candidates.** Any promoted lesson that is *deterministic* (a check a script could run: a migration journal diff, a branch divergence check, a secret grep, a contract smoke test) goes under a "Convert to hook or CI" heading with a one-line implementation sketch. Rule of thumb: **a lesson logged twice must become code or be consciously declined.**

5. **Log the pass.** Append one line per promoted insight to an "Insight-pull log" table in `90-patterns.md` (date, insight, action taken).

## Cadence

Run monthly, or after any week with 10 or more new insights. If `last_reviewed` on `90-patterns.md` is more than 45 days old, the `brain-loaded.sh` status line will already be flagging it. That is the trigger to run this.
