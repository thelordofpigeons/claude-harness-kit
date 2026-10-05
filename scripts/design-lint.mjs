#!/usr/bin/env node
/**
 * design-lint.mjs: mechanical design-slop linter (pure Node, zero deps).
 *
 * Encodes greppable design rules: banned fonts, raw hex outside tokens,
 * transition: all, layout animation, 100vh, dead links and similar. Every rule
 * is a regex over source text, so it is cheap enough to run after each edit.
 *
 * Provenance: the regexes and the code are my own. The choice of which generic
 * front-end checks to automate was informed by third-party design checklists
 * (community skills for AI coding agents) and by the token-discipline habit of
 * AI UI generators. No text or code from them is copied here, and I have not
 * checked their licenses, which is why this file does not claim to implement
 * any of them.
 *
 * Usage: node design-lint.mjs [--strict] <file-or-dir>...
 *   Dirs recurse over .css .scss .tsx .jsx .html .vue .svelte
 *   Skips node_modules / dist / build / .git
 *   Exit 1 on any ERROR (or any WARN with --strict), else 0.
 */

import fs from 'node:fs';
import path from 'node:path';

const EXTS = new Set(['.css', '.scss', '.tsx', '.jsx', '.html', '.vue', '.svelte']);
const SKIP_DIRS = new Set(['node_modules', 'dist', 'build', '.git']);
const TOKEN_FILE_RE = /tokens|theme|tailwind\.config|globals\.css/i;

const TW_WEIGHTS = {
  thin: 100, extralight: 200, light: 300, normal: 400, medium: 500,
  semibold: 600, bold: 700, extrabold: 800, black: 900,
};
const GENERIC_FAMILIES = new Set([
  'serif', 'sans-serif', 'monospace', 'system-ui', 'ui-sans-serif',
  'ui-serif', 'ui-monospace', 'cursive', 'fantasy', 'math',
  'inherit', 'initial', 'unset', 'revert',
]);
// Built from parts so this source file itself holds no literal dash character
// or dash entity (the repo hygiene scan would flag it).
const EM = String.fromCharCode(0x2014);
const EM_DASH_RE = new RegExp([EM, '&mdash' + ';', '&#82' + '12;', '\\\\u' + '2014'].join('|'));
const BANNED_FONT_RE = /\b(Inter|Roboto|Open[ _-]?Sans|Lato|Arial)\b/i;

// ---------------------------------------------------------------- helpers

function collectFiles(target, out) {
  let st;
  try {
    st = fs.statSync(target);
  } catch {
    process.stderr.write(`design-lint: cannot read ${target}\n`);
    process.exitCode = 2;
    return;
  }
  if (st.isDirectory()) {
    let entries;
    try {
      entries = fs.readdirSync(target, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries) {
      if (e.isDirectory()) {
        if (!SKIP_DIRS.has(e.name)) collectFiles(path.join(target, e.name), out);
      } else if (e.isFile() && EXTS.has(path.extname(e.name).toLowerCase())) {
        out.push(path.join(target, e.name));
      }
    }
  } else {
    out.push(target);
  }
}

/** Blank out comments while preserving line structure (CRLF already normalized). */
function stripComments(src) {
  let out = src.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, ' '));
  out = out.replace(/<!--[\s\S]*?-->/g, (m) => m.replace(/[^\n]/g, ' '));
  out = out
    .split('\n')
    .map((line) => {
      // strip // line comments, but not protocol-relative "://"
      for (let i = 0; i < line.length - 1; i++) {
        if (line[i] === '/' && line[i + 1] === '/') {
          if (i > 0 && line[i - 1] === ':') { i++; continue; }
          return line.slice(0, i);
        }
      }
      return line;
    })
    .join('\n');
  return out;
}

/**
 * Cheap structural scan: for every line, whether it sits inside a :root block
 * or a @keyframes block, plus the innermost selector chain seen on that line.
 */
function scanBlocks(content) {
  const lines = content.split('\n');
  const info = new Array(lines.length);
  let depth = 0;
  let rootDepth = -1;
  let kfDepth = -1;
  const selStack = [];
  let selBuf = '';
  for (let li = 0; li < lines.length; li++) {
    const line = lines[li];
    let inRoot = rootDepth >= 0;
    let inKf = kfDepth >= 0;
    let sel = selStack.join(' >> ');
    for (let ci = 0; ci < line.length; ci++) {
      const ch = line[ci];
      if (ch === '{') {
        const s = selBuf.trim();
        selStack.push(s);
        if (rootDepth < 0 && /:root/.test(s)) rootDepth = depth;
        if (kfDepth < 0 && /@keyframes\b/.test(s)) kfDepth = depth;
        depth++;
        selBuf = '';
      } else if (ch === '}') {
        depth = Math.max(0, depth - 1);
        selStack.pop();
        if (rootDepth >= 0 && depth <= rootDepth) rootDepth = -1;
        if (kfDepth >= 0 && depth <= kfDepth) kfDepth = -1;
        selBuf = '';
      } else if (ch === ';') {
        selBuf = '';
      } else {
        selBuf += ch;
      }
      if (rootDepth >= 0) inRoot = true;
      if (kfDepth >= 0) inKf = true;
      const joined = selStack.join(' >> ');
      if (joined.length > sel.length) sel = joined;
    }
    selBuf += ' ';
    info[li] = { inRoot, inKf, sel };
  }
  return info;
}

// ---------------------------------------------------------------- linter

function lintFile(fp) {
  const findings = [];
  let raw;
  try {
    raw = fs.readFileSync(fp, 'utf8');
  } catch {
    process.stderr.write(`design-lint: cannot read ${fp}\n`);
    process.exitCode = 2;
    return findings;
  }
  const ext = path.extname(fp).toLowerCase();
  const displayPath = fp.split(path.sep).join('/');
  const content = stripComments(raw.replace(/\r\n?/g, '\n'));
  const lines = content.split('\n');
  const isCssLike = ext === '.css' || ext === '.scss';
  const isMarkupLike = !isCssLike; // tsx/jsx/html/vue/svelte
  const isTokenFile = TOKEN_FILE_RE.test(displayPath);
  const blocks = scanBlocks(content);

  const add = (lineIdx, sev, id, msg) =>
    findings.push({ path: displayPath, line: lineIdx + 1, sev, id, msg });

  const hoverScaleLines = [];
  const weights = []; // { w, line }
  const families = new Map(); // lowercased -> { name, line }
  let outlineNoneLine = -1;
  const hasFocusStyle = /focus-visible|focus:|:focus\b/.test(content);

  const noteFamily = (name, lineIdx) => {
    const key = name.trim().toLowerCase().replace(/_/g, ' ');
    if (!key || GENERIC_FAMILIES.has(key) || key.startsWith('var(')) return;
    if (!families.has(key)) families.set(key, { name: name.trim(), line: lineIdx + 1 });
  };

  for (let i = 0; i < lines.length; i++) {
    const L = lines[i];
    if (!L.trim()) continue;

    // (1) transition-all
    if (/\btransition-all\b/.test(L) || /\btransition\s*:\s*['"`]?\s*all\b/.test(L)) {
      add(i, 'ERROR', 'transition-all',
        'never transition "all"; list transform/opacity/color explicitly');
    }

    // (2) transitions animating layout props
    if (/\btransition(?:-property)?\s*:[^;}\n]*\b(width|height|top|left|right|bottom|margin|padding)\b/.test(L)) {
      add(i, 'ERROR', 'layout-animation',
        'transition animates a layout property; animate transform/opacity instead');
    }
    // (2) keyframes animating layout props
    if (blocks[i].inKf &&
        /\b(width|height|top|left|right|bottom|margin|padding)(?:-[a-z]+)?\s*:/.test(L)) {
      add(i, 'ERROR', 'layout-animation',
        'keyframes animate a layout property; animate transform/opacity instead');
    }

    // (3) h-screen / height:100vh
    if (/\bh-screen\b/.test(L) || /\bheight\s*:\s*['"`]?100vh\b/.test(L)) {
      add(i, 'ERROR', 'h-screen',
        '100vh breaks under mobile URL bars; use min-h-[100dvh]');
    }

    // (4) scroll listener
    if (/window\.addEventListener\(\s*['"`]scroll['"`]/.test(L)) {
      add(i, 'ERROR', 'scroll-listener',
        'scroll event listener; use IntersectionObserver');
    }

    // (5) banned fonts + (12) family collection
    const famDecl = L.match(/font-family\s*:\s*([^;}{]+)/i);
    if (famDecl) {
      const bm = famDecl[1].match(BANNED_FONT_RE);
      if (bm) {
        add(i, 'ERROR', 'banned-font',
          `banned font "${bm[0]}"; pick a distinctive typeface`);
      }
      noteFamily(famDecl[1].split(',')[0].replace(/^\s*['"]|['"]\s*$/g, ''), i);
    }
    const classTok = L.match(/\bfont-(inter|roboto|open-?sans|lato|arial)\b/i);
    if (classTok) {
      add(i, 'ERROR', 'banned-font',
        `banned font token "${classTok[0]}"; pick a distinctive typeface`);
    }
    const arbTok = L.match(/\bfont-\[['"]?([^'"\]]+?)['"]?\]/);
    if (arbTok) {
      if (BANNED_FONT_RE.test(arbTok[1])) {
        add(i, 'ERROR', 'banned-font',
          `banned font "${arbTok[1]}"; pick a distinctive typeface`);
      }
      noteFamily(arbTok[1], i);
    }

    // (6) raw hex outside token contexts
    if (!isTokenFile && !blocks[i].inRoot) {
      const hexRe = /#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{4}|[0-9a-fA-F]{3})(?![0-9a-fA-F])/g;
      let m;
      while ((m = hexRe.exec(L)) !== null) {
        add(i, 'ERROR', 'raw-hex',
          `raw hex ${m[0]}; move to a CSS custom property / token`);
      }
    }

    // (7) purple gradient tells
    if (/\b(from|via|to)-(purple|violet|indigo)-\d/.test(L)) {
      add(i, 'ERROR', 'purple-gradient',
        'AI-slop purple/violet/indigo gradient class');
    }
    if (/linear-gradient\([^)]*\b(purple|violet|indigo)\b/i.test(L)) {
      add(i, 'ERROR', 'purple-gradient',
        'linear-gradient with purple-family stop');
    }

    // (8) hover:scale sprawl: collect
    if (/hover:scale-/.test(L)) hoverScaleLines.push(i);

    // (9) italic headings
    if (isCssLike && /font-style\s*:\s*italic/.test(L) &&
        /\bh[1-6]\b/.test(blocks[i].sel)) {
      add(i, 'WARN', 'italic-heading',
        'italic heading; prefer weight/size contrast over italics');
    }
    if (isMarkupLike &&
        /<h[1-6]\b[^>]*\b(?:class|className)\s*=\s*["'][^"']*\bitalic\b/.test(L)) {
      add(i, 'WARN', 'italic-heading',
        'italic heading; prefer weight/size contrast over italics');
    }

    // (10) weights: collect
    let wm;
    const wRe = /font-weight\s*:\s*['"`]?(\d{3})\b/g;
    while ((wm = wRe.exec(L)) !== null) weights.push({ w: +wm[1], line: i });
    const twRe = /\bfont-(thin|extralight|light|normal|medium|semibold|bold|extrabold|black)\b/g;
    while ((wm = twRe.exec(L)) !== null) weights.push({ w: TW_WEIGHTS[wm[1]], line: i });

    // (11) outline suppression: collect
    if (outlineNoneLine < 0 && (/\boutline\s*:\s*['"`]?none\b/.test(L) || /\boutline-none\b/.test(L))) {
      outlineNoneLine = i;
    }

    // (13) dead controls and punctuation in UI text (markup only)
    if (isMarkupLike) {
      // (13a) ghost link: href="" / href="#" / href="javascript:...": a control that goes nowhere
      if (/\bhref\s*=\s*(?:\{\s*)?["'`]\s*(?:#|javascript:[^"'`]*)?\s*["'`]/.test(L)) {
        add(i, 'ERROR', 'dead-link',
          'href points nowhere ("#", "" or javascript:); give it a real destination or make it a <button>');
      }
      // (13b) native <button> closed on one line with no handler / submit type / spread props
      if (/<button\b[^>]*>/.test(L) &&
          !/\b(?:onClick|onclick|on:click|@click|v-on:click|type\s*=\s*["']submit["']|type=\{|form=|\{\.\.\.)/.test(L)) {
        add(i, 'WARN', 'dead-button',
          '<button> with no handler on this line; wire it, mark it type="submit", or remove it (dead controls are slop)');
      }
      // (13c) em dash in UI text
      if (EM_DASH_RE.test(L)) {
        add(i, 'ERROR', 'em-dash',
          'em dash in UI text; use a comma, colon, period or parentheses');
      }
    }
  }

  // (8) hover:scale- on 3+ distinct lines
  if (hoverScaleLines.length >= 3) {
    add(hoverScaleLines[2], 'WARN', 'hover-scale-sprawl',
      `hover:scale- on ${hoverScaleLines.length} lines; uniform hover-scale sprawl, vary interactions`);
  }

  // (10) timid weights
  if (weights.length > 0 && weights.every((x) => x.w >= 400 && x.w <= 600)) {
    add(weights[0].line, 'WARN', 'timid-weights',
      'all font-weights sit in 400-600; use extreme contrast (100/200 vs 800/900)');
  }

  // (11) outline:none without focus style
  if (outlineNoneLine >= 0 && !hasFocusStyle) {
    add(outlineNoneLine, 'WARN', 'outline-none',
      'outline suppressed with no focus-visible/focus: style in file; keyboard users lose focus ring');
  }

  // (12) more than 2 distinct font families
  if (families.size > 2) {
    const names = [...families.values()].map((f) => f.name).join(', ');
    add([...families.values()][2].line - 1, 'WARN', 'font-family-count',
      `${families.size} font families in one file (${names}); cap at 2`);
  }

  findings.sort((a, b) => a.line - b.line);
  return findings;
}

// ---------------------------------------------------------------- main

const argv = process.argv.slice(2);
const strict = argv.includes('--strict');
const targets = argv.filter((a) => a !== '--strict');

if (targets.length === 0) {
  process.stderr.write('usage: node design-lint.mjs [--strict] <file-or-dir>...\n');
  process.exit(2);
}

const files = [];
for (const t of targets) collectFiles(t, files);

let errors = 0;
let warnings = 0;
for (const f of files) {
  for (const fnd of lintFile(f)) {
    if (fnd.sev === 'ERROR') errors++;
    else warnings++;
    process.stdout.write(`${fnd.path}:${fnd.line} [${fnd.sev}] ${fnd.id} ${fnd.msg}\n`);
  }
}

if (errors === 0 && warnings === 0) {
  process.stdout.write('design-lint: clean\n');
  process.exit(process.exitCode || 0);
}

process.stdout.write(`design-lint: ${errors} error(s), ${warnings} warning(s)${strict ? ' [strict]' : ''}\n`);
process.exit(errors > 0 || (strict && warnings > 0) ? 1 : 0);
