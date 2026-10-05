# 02. Model routing and effort tiers

**Problem.** Every agent call defaults to the session model. A review loop of fifteen agents on the most expensive model, most of them reading files and re-checking each other, costs a lot and adds little.

**Rule.** Set `model` explicitly on every agent call. Readers and mechanical implementers run on a cheaper model; the session model is kept for judgment (design direction, final verdicts, critical code).

**Where this shows up in the code.**

| Place | Setting |
|---|---|
| `workflows/review-until-dry.js`, scope pack | `model: 'sonnet'`, `effort: 'low'`, one agent, once |
| same file, tier `cheap` | finders haiku/low, dedup haiku/low, verify sonnet/low |
| same file, tier `standard` (default) | finders sonnet/low, dedup haiku/low, verify sonnet/medium |
| same file, tier `max` | finders and verifiers on the session model (medium and high effort), dedup still haiku |
| `workflows/design-variants.js`, judge | no model override, `effort: 'high'`: judgment stays on the session model |
| `agents/tracker.md`, `agents/ops-agent.md` | `model: haiku`: mechanical, bounded output |
| `templates/skills/ui-protocol/SKILL.md` | aesthetic direction never delegated to a small model; locked-design implementation and screenshot comparisons may be |

**Cost ceilings in the code.** `review-until-dry.js` takes `tokenBudget` (default 250000 output tokens) and stops when `budget.spent()` passes it, even mid-round. It caps findings per finder (default 8), verifies in batches of 6, and uses 3 lenses by default. `design-variants.js` takes `n` (default 3, at most 5), so at most five generators run plus one judge.

**Concurrency.** The workflow code bounds fan-out by those arguments, not by a scheduler. The working rule is to keep parallel agents to 3 or 4 per stage; this is a practice, not something the scripts enforce.

**What is not claimed.** The only figures here are the defaults above and the comment in `review-until-dry.js` that a typical document review on `standard` uses about 8 to 14 agents. No savings percentages are measured or claimed.

See also: [03 parallel agents](03-parallel-agents-and-verification.md), [04 adversarial review loops](04-adversarial-review-loops.md).
