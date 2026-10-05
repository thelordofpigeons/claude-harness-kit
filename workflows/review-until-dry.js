export const meta = {
  name: 'review-until-dry',
  description: 'Adversarial review loop with a convergence guard AND hard cost ceilings: tiered models, batched verification, semantic dedup, token budget. Stops after 2 dry rounds, maxRounds, or budget, whichever comes first.',
  whenToUse: 'Any review/iterate loop on a doc, deliverable, or diff. Args: {target: "<what to review + where ground truth lives>", maxRounds?: 3, lenses?: [...], tier?: "cheap"|"standard"|"max" (default standard: sonnet finders/verifiers at low/medium effort; max = session model for critical code), tokenBudget?: 250000 (output-token ceiling), maxFindingsPerFinder?: 8}. Typical doc review on standard: ~8-14 agents, well under 500k tokens. Runs are bounded by default (maxRounds, tokenBudget, batched verification).',
  phases: [
    { title: 'Scope', detail: 'one agent builds a ground-truth digest all reviewers share' },
    { title: 'Find', detail: 'adversarial reviewers, one lens each, capped findings, cheap tier' },
    { title: 'Verify', detail: 'fresh findings deduped then verified in BATCHES per file-group' },
  ],
}

const FINDINGS = {
  type: 'object',
  required: ['findings'],
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        required: ['file', 'summary', 'failure'],
        properties: {
          file: { type: 'string', description: 'file or artifact the finding anchors to' },
          summary: { type: 'string', description: 'one-sentence defect statement' },
          failure: { type: 'string', description: 'concrete input/state -> wrong output' },
        },
      },
    },
  },
}

const DEDUP = {
  type: 'object',
  required: ['unique'],
  properties: {
    unique: {
      type: 'array',
      description: 'indices (into the numbered input list) of findings to KEEP: one representative per distinct underlying defect, and none that restate an already-confirmed finding',
      items: { type: 'number' },
    },
  },
}

const VERDICTS = {
  type: 'object',
  required: ['verdicts'],
  properties: {
    verdicts: {
      type: 'array',
      items: {
        type: 'object',
        required: ['index', 'real', 'reason'],
        properties: {
          index: { type: 'number', description: 'index of the finding in the numbered input list' },
          real: { type: 'boolean', description: 'true only if verified against ground truth (files actually read)' },
          reason: { type: 'string' },
        },
      },
    },
  },
}

// ---- args & cost tiers ------------------------------------------------------
const target = (args && args.target) || String(args || '')
if (!target.trim()) throw new Error('review-until-dry needs args.target: what to review and where the ground truth lives')
const maxRounds = (args && args.maxRounds) || 3
const lenses = (args && args.lenses) || ['correctness', 'contracts-and-wiring', 'data-shapes-and-edge-cases']
const tier = (args && args.tier) || 'standard'
const tokenBudget = (args && args.tokenBudget) || 250000
const maxFindingsPerFinder = (args && args.maxFindingsPerFinder) || 8
const VERIFY_BATCH = 6

// cheap: everything small/low. standard: sonnet, low find / medium verify.
// max: session model for find+verify (critical code only); still budget-capped.
const T = {
  cheap:    { find: { model: 'haiku', effort: 'low' },  dedup: { model: 'haiku', effort: 'low' }, verify: { model: 'sonnet', effort: 'low' } },
  standard: { find: { model: 'sonnet', effort: 'low' }, dedup: { model: 'haiku', effort: 'low' }, verify: { model: 'sonnet', effort: 'medium' } },
  max:      { find: { effort: 'medium' },               dedup: { model: 'haiku', effort: 'low' }, verify: { effort: 'high' } },
}[tier] || {}

const spent0 = budget.spent()
const spentHere = () => budget.spent() - spent0
const overBudget = () => spentHere() >= tokenBudget

// ---- helpers ----------------------------------------------------------------
// Normalized key: lowercase, collapse whitespace, strip digits/punct so trivial
// rewordings collide. Semantic dedup is still done by the dedup agent; this key
// only pre-filters exact-ish repeats for free.
const key = f => `${f.file}|${f.summary}`.toLowerCase().replace(/[^a-z ]+/g, ' ').replace(/\s+/g, ' ').trim()
const chunk = (arr, n) => arr.reduce((acc, x, i) => ((i % n ? acc[acc.length - 1].push(x) : acc.push([x])), acc), [])

// ---- Scope: shared ground-truth digest (one agent, once) ---------------------
phase('Scope')
const digest = await agent(
  `Build a REVIEW SCOPE PACK for the following target. Read the target artifact and skim the ground-truth sources. Output (max 900 words): (1) file map: every relevant file with a one-line role; (2) the target's key claims/contracts that reviewers should check; (3) known-good context reviewers should NOT re-report. Raw data for other agents, be dense.\n\n${target}`,
  { label: 'scope-pack', phase: 'Scope', model: 'sonnet', effort: 'low' },
)

// ---- Find/Verify loop ---------------------------------------------------------
const seen = new Set()
const seenSummaries = [] // every post-dedup finding ever, confirmed OR refuted; string keys
                         // cannot catch cross-round rewordings (fixture-tested), the dedup
                         // agent needs this list or refuted findings re-enter reworded
const confirmed = []
let dry = 0
let round = 0
let stopReason = ''

while (dry < 2 && round < maxRounds) {
  if (overBudget()) { stopReason = `token budget (${tokenBudget}) reached after ${round} round(s)`; break }
  round++

  const found = (await parallel(lenses.map(l => () =>
    agent(
      `Round ${round}. Adversarially review the target through the ${l} lens.\n\nSCOPE PACK (shared context: trust it for orientation, read files to confirm anything you report):\n${digest}\n\nTARGET:\n${target}\n\nReturn AT MOST ${maxFindingsPerFinder} findings, most severe first, code-verifiable only (name the file and the concrete failure). No style opinions, no micro-UX nitpicks. Do NOT re-report (semantically, not just verbatim): ${[...seen].slice(0, 40).join('; ') || 'none yet'}.`,
      { phase: 'Find', label: `find:${l}:r${round}`, schema: FINDINGS, ...T.find },
    ),
  ))).filter(Boolean).flatMap(r => (r.findings || []).slice(0, maxFindingsPerFinder))

  let fresh = found.filter(f => !seen.has(key(f)))
  log(`round ${round}: ${found.length} findings, ${fresh.length} past exact-dedup (${spentHere()} tokens spent)`)

  // Semantic dedup: one cheap agent collapses rewordings and drops restatements
  // of already-confirmed findings. Duplicates were the main cost driver of an
  // earlier unbounded run (many "confirmed" findings were one defect reworded,
  // each re-verified in full).
  if (fresh.length > 1) {
    const numbered = fresh.map((f, i) => `[${i}] ${f.file} :: ${f.summary}`).join('\n')
    const already = seenSummaries.slice(-40).join('; ') || 'none'
    const d = await agent(
      `Cluster these review findings by UNDERLYING DEFECT (same root issue reworded = same cluster). Keep ONE representative index per cluster (the most precise). Drop any finding that restates, even reworded, one from the ALREADY-SEEN list (those were previously confirmed or refuted; either way they must not be re-verified).\n\nFindings:\n${numbered}\n\nALREADY-SEEN: ${already}`,
      { phase: 'Verify', label: `dedup:r${round}`, schema: DEDUP, ...T.dedup },
    )
    if (d && Array.isArray(d.unique)) fresh = d.unique.filter(i => fresh[i]).map(i => fresh[i])
    log(`round ${round}: ${fresh.length} unique after semantic dedup`)
  }
  fresh.forEach(f => { seen.add(key(f)); seenSummaries.push(f.summary) })

  let real = []
  if (fresh.length) {
    if (overBudget()) { stopReason = `token budget (${tokenBudget}) reached mid-round ${round}: ${fresh.length} findings left UNVERIFIED`; log(stopReason); break }
    // Batched verification: one verifier per group of findings (grouped by file
    // so each verifier reads a coherent slice of ground truth ONCE), instead of
    // one full-price agent per finding.
    const byFile = [...fresh].sort((a, b) => String(a.file).localeCompare(String(b.file)))
    const groups = chunk(byFile, VERIFY_BATCH)
    const judged = (await parallel(groups.map(g => () => {
      const numbered = g.map((f, i) => `[${i}] ${JSON.stringify(f)}`).join('\n')
      return agent(
        `Verify EACH numbered finding against GROUND TRUTH (read the actual files, do not trust the reviewers). Default real=false when you cannot locate/reproduce it. Return one verdict per index.\n\n${numbered}\n\nContext: ${target}`,
        { phase: 'Verify', label: `verify:r${round}`, schema: VERDICTS, ...T.verify },
      ).then(v => (v && v.verdicts || []).filter(x => g[x.index]).map(x => ({ ...g[x.index], real: !!x.real, reason: x.reason })))
    }))).filter(Boolean).flat()
    real = judged.filter(j => j.real)
    confirmed.push(...real)
  }

  if (real.length === 0) dry++
  else dry = 0
}

if (!stopReason) stopReason = dry >= 2
  ? 'converged: 2 consecutive rounds with no new code-verifiable blocker'
  : `maxRounds (${maxRounds}) reached: findings may not be exhausted`

log(`done: ${confirmed.length} confirmed, ${round} round(s), ~${spentHere()} output tokens, tier=${tier}`)
return { confirmed, rounds: round, stopped: stopReason, tier, outputTokensApprox: spentHere() }
