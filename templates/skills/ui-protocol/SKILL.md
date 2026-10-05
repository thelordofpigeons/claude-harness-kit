---
name: ui-protocol
description: UI/UX 3-phase protocol (COMMIT, BUILD, VERIFY). Invoke BEFORE any UI work: build, create, design, implement, style or modify components, pages, screens, frontends, design systems, motion, or anything described as beautiful, polished, modern, or with a named aesthetic.
---

# UI/UX protocol: COMMIT, BUILD, VERIFY

Follow this protocol for any UI work. Never self-grade in VERIFY: the evaluator is a different agent from the builder.

**Triage first.**
- Component scope (one component, or one fix on an already-designed surface, no new page): skip COMMIT and VERIFY steps 2 to 4. Keep tokens-only styling, the hooks, and one `shot.mjs` check of the touched surface at 1440 and 375.
- Full protocol for anything else: a new page, route or screen, a new product surface, client-facing work, or the user says polish, redesign or beautiful.

## Wired tooling (use it, do not rediscover it)

- `node ~/.claude/scripts/shot.mjs <url> <outDir> --widths=1440,768,375 --full`: CDP device-emulated screenshots plus a JSON report (viewport truth, horizontal overflow, touch targets under 44px, console errors, fonts). It is the only trusted way to see 375 or 390. Bare `--window-size` mobile captures lie, because layout clamps near 500px. Exit code 4 means the page was unreachable (dead dev server, browser error page): those PNGs are error pages, never grade them, restart the server.
- Hooks (see `docs/05-hooks-as-enforcement.md`):
  - `design-lint-hook.sh` blocks on ERROR findings (banned font, raw hex in components, `transition: all`).
  - `frontend-format.sh` runs the repo's own prettier and eslint per edit.
  - `frontend-typecheck.sh` runs the repo's own `tsc` at Stop (at most 2 blocking rounds).

### Browser tool division of labor

| Job | Tool | Do not use instead |
|---|---|---|
| Viewport-truth screenshots at 1440, 768, 375 for BUILD checkpoints and design review | `shot.mjs` | An MCP browser's screenshot or resize tools. Not verified to apply the same device-metrics override; substituting it reintroduces the clamp bug the harness exists to catch. |
| Click-through smoke test, console and network inspection, Lighthouse, performance traces on a local dev server | A disposable-browser DevTools MCP | A browser tool that drives your real profile (a dev-server smoke test never needs cookies) |
| Anything that needs your real logged-in session | A browser extension that drives your real profile | A disposable browser (no session) |

Overlap exists (several tools can navigate, click and read the console). The split above is the rule, not a suggestion.

## COMMIT (before any code)

1. Read the repo's `DESIGN.md` if present, and a project taste file if you keep one (`~/.claude/taste.md`, user-supplied). Keep a project-local log of shipped designs (palette family, display face, macrostructure, signature). A new design must differ from the last 5 log entries on at least one axis.
2. If the project has a locked brand, palette and font families are frozen. Only macrostructure, composition and signature vary.
3. Emit a declared design brief in chat before coding:
   - **Design read**: "Reading this as: [page kind] for [audience], [vibe], leaning [aesthetic family]."
   - **Dials**: VARIANCE n/10, MOTION n/10, DENSITY n/10
   - **Tokens**: 3 to 5 named colors (hex plus usage intent), at most 2 font families (none from the banned-font list in `scripts/design-lint.mjs`), spacing base, radius scale
   - **Signature**: the one element this design will be remembered by
4. Run the `design-variants` workflow (`workflows/design-variants.js`, args `{brief, outDir, n:3}`) when ANY objective trigger holds: new route or page, new product surface, client-facing or external audience, landing or marketing page, user says polish, redesign or beautiful. Otherwise skip it. Build from the judged winner plus the merge notes.
5. Model routing: the brief and every judging step stay on the session model at high effort. Never delegate aesthetic direction to a small model.

## BUILD

- Every color, font and spacing value goes through CSS custom properties or the framework's tokens. No raw values in components (the lint blocks them).
- Pull component primitives from your component registry or library of choice, then restyle to the brief. Never ship library defaults unchanged.
- **Mid-build visual checkpoints (mandatory).** After the first section renders and after each major section: serve the page over HTTP, run `shot.mjs` at 1440 and 375, Read the PNGs, list every difference from the committed brief, fix. At most 3 rounds per surface.
- Implementing an already-locked design, and the mid-build screenshot comparisons, may run on a smaller-model subagent.
- Motion: transforms and opacity only. Respect `prefers-reduced-motion`.

## VERIFY (mandatory, produces artifacts)

1. `node ~/.claude/scripts/design-lint.mjs <dir>` is clean.
2. Review the changed files against a written web-interface checklist (a smaller-model subagent is fine).
3. Spawn the `design-review` agent (`agents/design-review.md`): a separate evaluator, never the builder, using `shot.mjs`. Fix all [Blocker] and [High-Priority] items.
4. If motion shipped, review it on its own. Accessibility: a static lint pass always, plus a runtime axe scan for client-facing surfaces.
5. Interaction states and motion rules, plus a truthfulness check: no invented numbers, quotes or claims, no navigation links that go nowhere.
6. **Click-through smoke test** (full protocol only). Serve the page, then drive it with a DevTools MCP: take a snapshot to enumerate every interactive element, click each one, record what happened (route change, dialog, state change, console error). One line of evidence per element in the VERIFY report. A control that does nothing is a [Blocker]. Never write "all buttons work" without the per-element log. A smaller-model subagent may run this.
7. Append the shipped design to the project-local design log.
8. When the user praises or rejects a design in chat, record it in the taste file in that same turn.

## Annotated webpage screenshots

When a task needs a webpage screenshot delivered as a real PNG with annotations or a precise crop (bug reports, audits, before and after captures), use headless Chrome for the capture, CSS negative offsets for the crop, SVG overlays for annotations, and a crisp 2x re-render. No image-editing dependencies are needed.
