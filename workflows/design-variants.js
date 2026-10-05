export const meta = {
  name: 'design-variants',
  description: 'High-stakes UI exploration: N divergent variants from opposed aesthetic frames -> CDP-emulated screenshots at 1440 and 390 -> one pairwise visual judge (high effort) -> winner + merge notes for grafting the best of the runners-up. Args: {brief, outDir, n?=3 (max 5), shotScript?=~/.claude/scripts/shot.mjs, bannedFonts?}.',
  phases: [
    { title: 'Diverge', detail: 'n parallel generator agents, one aesthetic frame each; each writes variant-<i>.html and screenshots it to variant-<i>.png' },
    { title: 'Judge', detail: 'one judge Reads every PNG, compares pairwise (relative beats absolute), returns winner + ranking + merge notes' },
  ],
}

// Opposed aesthetic frames: divergence comes from the frame, not from asking
// the model to "be creative" n times (that converges on the same answer).
// Path to the screenshot tool, as the agents' Bash tool will see it. Default is the
// install location from the README (a relative path would resolve against the user's
// project, not the kit). Override with args.shotScript.
const SHOT = (args && args.shotScript) || '~/.claude/scripts/shot.mjs'

const FRAMES = [
  'editorial-minimal: typographic, restrained, whitespace as structure',
  'bold-maximal: dense, layered, oversized display type, one loud accent',
  'technical-terminal: mono grid, data-first, precise hairlines',
  'cinematic-dark: near-black atmosphere, dramatic imagery, glow used once',
  'warm-humanist: organic shapes, tactile palette, friendly type',
]

// Hard rules every variant must obey regardless of frame (hard-rules floor).
// Override with args.bannedFonts (array of family names).
const BANNED_FONTS = (args && args.bannedFonts) || ['Inter', 'Roboto', 'system-ui']

const HARD_RULES = [
  'max 2 font families total',
  `NEVER ${BANNED_FONTS.join(", ")}: pick characterful faces`,
  '3-5 colors, declared as CSS custom properties in :root',
  'no purple gradients',
  'no transition-all (transition specific properties only)',
].join('; ')

const VARIANT_SUMMARY = {
  type: 'object',
  required: ['file', 'png', 'png_mobile', 'mobile_clean', 'palette', 'display_face', 'macrostructure', 'signature'],
  properties: {
    file: { type: 'string', description: 'absolute path of the variant HTML file written' },
    png: { type: 'string', description: 'absolute path of the 1440 desktop screenshot PNG (empty string ONLY if Chrome could not be found)' },
    png_mobile: { type: 'string', description: 'absolute path of the 390 mobile-emulated screenshot PNG (empty string if capture failed)' },
    mobile_clean: { type: 'boolean', description: 'true if shot.mjs reported no horizontal overflow and no touch targets under 44px at 390' },
    palette: { type: 'array', items: { type: 'string' }, description: 'the 3-5 hex colors used, as declared in :root' },
    display_face: { type: 'string', description: 'the display font family used' },
    macrostructure: { type: 'string', description: 'one sentence: the page\'s layout skeleton (e.g. "split hero, 12-col feature grid, full-bleed footer")' },
    signature: { type: 'string', description: 'the single most distinctive move of this variant: what a viewer would remember' },
  },
}

const JUDGMENT = {
  type: 'object',
  required: ['winner_index', 'ranking', 'merge_notes', 'per_variant_findings'],
  properties: {
    winner_index: { type: 'number', description: '0-based index of the winning variant' },
    ranking: { type: 'array', items: { type: 'number' }, description: 'all variant indices, best first' },
    merge_notes: { type: 'string', description: 'concrete, actionable notes: what to graft from the runners-up onto the winner (specific elements, treatments, moves, not vibes)' },
    per_variant_findings: {
      type: 'array',
      items: {
        type: 'object',
        required: ['index', 'strengths', 'weaknesses'],
        properties: {
          index: { type: 'number' },
          strengths: { type: 'string' },
          weaknesses: { type: 'string' },
        },
      },
    },
  },
}

async function run() {
  const { brief, outDir, n = 3 } = args || {}
  if (!brief || !outDir) throw new Error('args: {brief, outDir, n?}')

  const frames = FRAMES.slice(0, Math.max(1, Math.min(n, FRAMES.length)))
  log(`design-variants: ${frames.length} frames, out=${outDir}`)

  // ---- Diverge: n parallel generators, one frame each -----------------------
  phase('Diverge')
  const variants = await parallel(frames.map((frame, i) => () =>
    agent(
      [
        'You are in DIVERGENT mode: a generator, not a critic. Do not produce the first obvious answer. Commit fully to your assigned aesthetic frame and push it further than feels safe.',
        '',
        `BRIEF:\n${brief}`,
        '',
        `YOUR AESTHETIC FRAME (commit to it completely): ${frame}`,
        '',
        `HARD RULES (non-negotiable): ${HARD_RULES}.`,
        '',
        'DELIVERABLE (all three steps):',
        `1. Write ONE self-contained variant HTML file to ${outDir}/variant-${i}.html: all CSS inline in a <style> block, real content derived from the brief (no lorem ipsum), no external assets except Google Fonts <link> tags, no ES modules (the file is opened over file://). Design for a 1440x900 viewport above the fold AND make it hold at 390px wide: no horizontal overflow, clickable targets at least 44x44 CSS px, root overflow-x: clip.`,
        `2. Screenshot it with the CDP tool (real device emulation, never bare --window-size): node ${SHOT} "file:///<absolute html path with forward slashes>" "${outDir}/v${i}" --widths=1440,390 --wait=2500 > "${outDir}/v${i}.json". It writes ${outDir}/v${i}/shot-1440.png and ${outDir}/v${i}/shot-390.png and prints a JSON report; copy or reference those paths as png / png_mobile. Read the JSON: if horizontalOverflow is true or smallTouchTargets is non-empty at 390, fix the HTML and re-shoot once, then set mobile_clean accordingly. Create ${outDir} first if it does not exist. Verify both PNGs exist and are non-trivial in size before returning.`,
        '3. Return the JSON summary of what you built.',
      ].join('\n'),
      { phase: 'Diverge', label: `variant-${i}:${frame.split(':')[0]}`, schema: VARIANT_SUMMARY },
    ),
  ))

  const made = variants.filter(v => v && v.png)
  log(`Diverge done: ${made.length}/${frames.length} variants have screenshots`)
  if (made.length === 0) throw new Error('Diverge produced no screenshots: nothing to judge')

  // ---- Judge: ONE agent, visual pairwise comparison --------------------------
  phase('Judge')
  const roster = variants
    .map((v, i) => `[${i}] frame="${frames[i]}" html=${v && v.file} png=${v && v.png} png_mobile=${v && v.png_mobile} mobile_clean=${v && v.mobile_clean} signature="${v && v.signature}" macrostructure="${v && v.macrostructure}" palette=${JSON.stringify((v && v.palette) || [])} display_face="${v && v.display_face}"`)
    .join('\n')

  const judgment = await agent(
    [
      'You are the design judge for a high-stakes UI shootout. Judge with your EYES, not the metadata.',
      '',
      `Read (visually inspect) EVERY screenshot listed below with your Read tool: each variant has a 1440 desktop PNG and a 390 mobile PNG. Judge the desktop render for design quality and the mobile render for whether the concept survives a phone (a variant with mobile_clean=false or a broken 390 render cannot win outright; note what merge would fix it). If a PNG is missing or unreadable, fall back to reading that variant's HTML and judge it from the code, noting the handicap.`,
      '',
      `BRIEF the variants were built against:\n${brief}`,
      '',
      `VARIANTS:\n${roster}`,
      '',
      'METHOD: pairwise, not absolute (relative judgment beats absolute scoring):',
      '1. Look at every PNG first, silently. Write your per-variant observations (what is literally on screen, desktop and mobile) BEFORE any ranking; self-preference bias drops when the verdict comes after explicit reasoning.',
      '2. Compare each PAIR head-to-head on: design quality (hierarchy, spacing rhythm, typographic craft), originality (would a designer stop scrolling?), craft (alignment, contrast, detail finish), and brief-fit.',
      '3. Derive the ranking from the pairwise wins, then sanity-check the top pick against the brief once more.',
      '4. Write merge_notes as a graft list: the specific elements, treatments, or moves from each runner-up that would make the winner stronger: concrete enough that a builder agent could apply them without seeing your reasoning.',
      '',
      'Be harsh on generic output: a competent-but-forgettable variant loses to a flawed-but-memorable one when the flaw is fixable via merge_notes.',
    ].join('\n'),
    { phase: 'Judge', label: 'pairwise-judge', schema: JUDGMENT, effort: 'high' },
  )

  log(`Judge done: winner=[${judgment && judgment.winner_index}] ranking=${JSON.stringify(judgment && judgment.ranking)}`)
  return { variants, judgment }
}

// The workflow runtime wraps the script body in an async function, so a
// top-level `return` is the contract for delivering the result (see the
// sibling review-until-dry.js). Plain `node --check` rejects this line;
// that is expected and fine.
return await run()
