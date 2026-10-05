# 03. Parallel agents and batched verification

**Problem.** Parallel agents given the same prompt converge on the same answer. Verifying each result with its own full-price agent makes verification the dominant cost.

**Mechanisms.**

1. **Divergence comes from the frame, not from asking for creativity.** `workflows/design-variants.js` holds a list of opposed aesthetic frames (editorial-minimal, bold-maximal, technical-terminal, cinematic-dark, warm-humanist). Each generator gets exactly one frame plus a shared floor of hard rules (font families, color count, no `transition: all`). Asking the same model to "be creative" n times is the failure mode this avoids.
2. **Generators produce evidence, not claims.** Each one writes a self-contained HTML file and screenshots it with `scripts/shot.mjs` at 1440 and 390 (device emulation, with overflow and touch-target measurements). The return value is a schema-checked summary, including whether the mobile render was clean.
3. **One judge, pairwise.** A single high-effort agent reads every PNG, writes per-variant observations first, then compares pairs head to head. Relative judgment beats absolute scores. Its output is a winner, a ranking, and merge notes that a builder can apply without seeing the reasoning. A variant with a broken mobile render cannot win outright.
4. **Disjoint targets for implementers.** When the work is code rather than design, parallel agents get disjoint file sets, so there are no merge conflicts and no overlapping edits. The task-gate skill says so at the planning step.
5. **Batched verification.** In `workflows/review-until-dry.js`, findings are sorted by file and verified in groups of 6 per verifier. Each verifier reads one coherent slice of ground truth once, instead of one agent per finding re-reading the same files. The default verdict is "not real" when the finding cannot be reproduced.
6. **The builder never grades itself.** `agents/design-review.md` is read-only and is never the agent that built the UI. It turns measured JSON into findings mechanically (overflow, small targets, console errors) before it looks at any image.

**Runtime note.** The workflow scripts run only inside the Workflow runtime. A top-level `return` in them is the contract for delivering the result, so plain `node --check` rejects those lines. That is expected.

**Limits.** The judge is a model. Its pairwise verdicts are only as good as the screenshots and the brief; the merge notes are a starting point for a human.

See also: [02 model routing](02-model-routing.md), [04 adversarial review loops](04-adversarial-review-loops.md).
