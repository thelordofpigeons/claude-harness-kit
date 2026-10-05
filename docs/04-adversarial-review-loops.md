# 04. Adversarial review loops with convergence guards

**Problem.** "Review until it is clean" has no stopping rule. An earlier unbounded run produced mostly duplicate findings, each re-verified at full price. The lesson was: the loop needs ceilings and a way to stop.

**The loop** (`workflows/review-until-dry.js`):

1. **Scope.** One agent builds a shared scope pack: a file map, the claims to check, and known-good context reviewers should not re-report.
2. **Find.** One finder per lens (default: correctness, contracts and wiring, data shapes and edge cases), in parallel. Each returns at most `maxFindingsPerFinder` findings, schema-checked, code-verifiable only: no style opinions.
3. **Dedup.** Two stages. A free normalized-key filter removes exact repeats. Then one cheap agent clusters the rest by underlying defect and drops anything that restates an earlier finding, confirmed or refuted. The dedup agent needs the list of already-seen summaries because string keys cannot catch rewordings across rounds.
4. **Verify.** Surviving findings are verified against the actual files in batches of 6 (see [03](03-parallel-agents-and-verification.md)).
5. **Stop.** The loop ends at the first of:
   - 2 consecutive dry rounds (no newly confirmed finding): "converged"
   - `maxRounds` (default 3)
   - `tokenBudget` (default 250000 output tokens), checked before each round and before verification

**What the result says.** It returns the confirmed findings, the rounds run, the approximate output tokens, the tier, and a stop reason. A budget stop mid-round reports how many findings were left unverified, so the output never claims more than was checked.

**Why two dry rounds.** One empty round can be luck (a finder that happened to look elsewhere). Two in a row with different lenses seeing the same ground truth is a reasonable, cheap signal.

**Lenses and tiers are arguments.** `lenses`, `tier`, `maxRounds`, `tokenBudget` and `target` come from the caller, so the same script serves a document review and a diff review.

**Limits.** "Converged" means the finders stopped finding things under these lenses, not that the target is correct. A missing lens is invisible to the loop. Verification relies on the verifier actually reading the files; the schema asks for a reason per verdict so a skimming verifier is at least visible.

See also: [02 model routing](02-model-routing.md), `workflows/review-until-dry.js`.
