#!/usr/bin/env node
/**
 * shot.mjs: trustworthy viewport screenshots via Chrome DevTools Protocol.
 * Plain Node 22+ (global fetch + WebSocket), zero dependencies, no Puppeteer.
 *
 * Why: headless desktop Chrome silently clamps layout width to ~500 CSS px even
 * with --window-size=375,..., so mobile media queries never fire and the PNG
 * lies. Emulation.setDeviceMetricsOverride
 * gives a real 375/390/768 layout.
 *
 * Usage:
 *   node shot.mjs <url> <outDir> [--widths=1440,768,375] [--full] [--wait=ms] [--json]
 *
 *   url      http(s)://... or file:///C:/path/page.html (ES modules die on file://; serve over HTTP)
 *   outDir   directory for shot-<width>.png (created if missing)
 *   --widths comma list; < 768 => mobile emulation (dpr 2, touch), >= 768 => desktop (dpr 1)
 *   --full   capture beyond the viewport (full page height) in addition to the fold shot
 *   --wait   settle time after load, default 2500ms (raise for JS-heavy pages)
 *   --json   print the JSON report only (default prints a human summary + JSON)
 *   --cookie "name=value; name2=value2" set cookie(s) on the target's origin before navigating
 *            (each pair is set via Network.setCookie against the target URL's own domain/path,
 *            so an authenticated app route can be shot without a real login flow)
 *
 * Per width the report includes: viewport truth (innerWidth, matchMedia probe),
 * horizontal overflow (scrollWidth vs innerWidth + offending elements),
 * clickable targets under 44x44 CSS px, console errors, failed requests, and
 * the PNG paths. Exit 0 on success, 2 on timeout, 3 if Chrome never exposed a target,
 * 4 if any width landed on a Chrome error page (dead server; PNGs are not gradeable).
 */

import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

const argv = process.argv.slice(2);
const positional = argv.filter((a) => !a.startsWith('--'));
const flag = (name, dflt) => {
  const hit = argv.find((a) => a === `--${name}` || a.startsWith(`--${name}=`));
  if (!hit) return dflt;
  const eq = hit.indexOf('=');
  return eq === -1 ? true : hit.slice(eq + 1);
};

const url = positional[0];
const outDir = positional[1];
if (!url || !outDir) {
  process.stderr.write('usage: node shot.mjs <url> <outDir> [--widths=1440,768,375] [--full] [--wait=ms] [--json]\n');
  process.exit(1);
}
const widths = String(flag('widths', '1440,768,375')).split(',').map((w) => Number(w.trim())).filter(Boolean);
const full = Boolean(flag('full', false));
const settle = Number(flag('wait', 2500));
const jsonOnly = Boolean(flag('json', false));
const cookieFlag = flag('cookie', null);

fs.mkdirSync(outDir, { recursive: true });

const CHROME_CANDIDATES = [
  process.env.CHROME_PATH,
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
  'C:/Program Files (x86)/Google/Chrome/Application/chrome.exe',
  path.join(process.env.LOCALAPPDATA || '', 'Google/Chrome/Application/chrome.exe'),
  '/usr/bin/google-chrome',
  '/usr/bin/chromium',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
].filter(Boolean);
const chrome = CHROME_CANDIDATES.find((p) => fs.existsSync(p));
if (!chrome) {
  process.stderr.write('shot: chrome.exe not found; set CHROME_PATH\n');
  process.exit(1);
}

const log = (...a) => { if (!jsonOnly) process.stderr.write(`[shot] ${a.join(' ')}\n`); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const port = 9222 + Math.floor(Math.random() * 500);
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'shot-profile-'));

// Sweep profiles leaked by earlier runs (crash, kill, or an exit()
// that fired before the deferred rm). Anything older than
// 1h cannot belong to a live run (global timeout is 90s).
try {
  const cutoff = Date.now() - 60 * 60 * 1000;
  for (const name of fs.readdirSync(os.tmpdir())) {
    if (!name.startsWith('shot-profile-')) continue;
    const p = path.join(os.tmpdir(), name);
    try { if (fs.statSync(p).mtimeMs < cutoff) fs.rmSync(p, { recursive: true, force: true }); } catch {}
  }
} catch {}

const timer = setTimeout(async () => { log('global timeout'); await cleanup(); process.exit(2); }, 90000);
timer.unref();

const proc = spawn(chrome, [
  '--headless=new',
  `--remote-debugging-port=${port}`,
  '--remote-allow-origins=*',
  '--no-first-run',
  '--no-default-browser-check',
  '--disable-gpu',
  '--hide-scrollbars',
  '--allow-file-access-from-files',
  `--user-data-dir=${profile}`,
  'about:blank',
], { stdio: ['ignore', 'ignore', 'pipe'] });

// Kill Chrome, wait for it to actually exit (it holds locks inside the profile),
// then remove the profile. Must be awaited before process.exit(): a
// deferred-timer version never runs because exit() fires first, which leaks
// one ~20MB profile dir per invocation.
async function cleanup() {
  const exited = new Promise((res) => { if (proc.exitCode !== null) return res(); proc.once('exit', res); setTimeout(res, 3000).unref(); });
  try { proc.kill(); } catch {}
  await exited;
  for (let i = 0; i < 5; i++) {
    try { fs.rmSync(profile, { recursive: true, force: true }); return; } catch {}
    await sleep(200);
  }
  try { proc.kill('SIGKILL'); fs.rmSync(profile, { recursive: true, force: true }); } catch {}
}

let targets = [];
for (let i = 0; i < 60; i++) {
  try {
    targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
    if (targets.length) break;
  } catch {}
  await sleep(250);
}
if (!targets.length) { log('no CDP target'); await cleanup(); process.exit(3); }
const pageT = targets.find((t) => t.type === 'page') || targets[0];
const ws = new WebSocket(pageT.webSocketDebuggerUrl);
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = (e) => rej(e); });

let id = 0;
const pending = new Map();
const consoleErrors = [];
const failedRequests = [];
ws.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); return; }
  if (m.method === 'Runtime.consoleAPICalled' && (m.params.type === 'error' || m.params.type === 'warning')) {
    consoleErrors.push(`${m.params.type}: ${m.params.args.map((a) => a.value ?? a.description ?? '').join(' ').slice(0, 200)}`);
  }
  if (m.method === 'Runtime.exceptionThrown') {
    consoleErrors.push(`exception: ${(m.params.exceptionDetails.exception?.description || m.params.exceptionDetails.text || '').slice(0, 200)}`);
  }
  if (m.method === 'Network.loadingFailed') failedRequests.push(m.params.errorText);
  if (m.method === 'Network.responseReceived' && m.params.response.status >= 400) {
    failedRequests.push(`${m.params.response.status} ${m.params.response.url.slice(0, 120)}`);
  }
};
const send = (method, params = {}) => new Promise((res) => { const i = ++id; pending.set(i, res); ws.send(JSON.stringify({ id: i, method, params })); });
const evaluate = async (expression) => {
  const r = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
  return r.result?.result?.value;
};

await send('Page.enable');
await send('Runtime.enable');
await send('Network.enable');

if (cookieFlag) {
  const target = new URL(url);
  for (const pair of String(cookieFlag).split(';')) {
    const eq = pair.indexOf('=');
    if (eq === -1) continue;
    const name = pair.slice(0, eq).trim();
    const value = pair.slice(eq + 1).trim();
    if (!name) continue;
    const r = await send('Network.setCookie', {
      name, value, domain: target.hostname, path: '/', url: target.origin,
    });
    log(`cookie ${name}: ${JSON.stringify(r.result)}`);
  }
}

const PROBE = `(() => {
  const de = document.documentElement;
  const iw = window.innerWidth;
  const sw = Math.max(de.scrollWidth, document.body ? document.body.scrollWidth : 0);
  const offenders = [];
  if (sw > iw + 1) {
    for (const el of document.querySelectorAll('body *')) {
      const r = el.getBoundingClientRect();
      if (r.right > iw + 1 && r.width > 0 && r.height > 0) {
        offenders.push((el.tagName.toLowerCase() + (el.id ? '#' + el.id : '') + (el.className && typeof el.className === 'string' ? '.' + el.className.trim().split(/\\s+/).slice(0,2).join('.') : '')) + ' right=' + Math.round(r.right));
        if (offenders.length >= 8) break;
      }
    }
  }
  const small = [];
  for (const el of document.querySelectorAll('a[href],button,[role=button],input:not([type=hidden]),select,textarea,summary')) {
    const r = el.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) continue;
    const cs = getComputedStyle(el);
    if (cs.visibility === 'hidden' || cs.display === 'none') continue;
    if (r.width < 44 || r.height < 44) {
      small.push((el.tagName.toLowerCase() + (el.id ? '#' + el.id : '')) + ' ' + Math.round(r.width) + 'x' + Math.round(r.height) + ' "' + (el.textContent || el.getAttribute('aria-label') || '').trim().slice(0, 24) + '"');
      if (small.length >= 12) break;
    }
  }
  return {
    innerWidth: iw,
    innerHeight: window.innerHeight,
    documentHeight: Math.max(de.scrollHeight, document.body ? document.body.scrollHeight : 0),
    devicePixelRatio: window.devicePixelRatio,
    mqMaxWidth768: matchMedia('(max-width: 768px)').matches,
    mqMaxWidth480: matchMedia('(max-width: 480px)').matches,
    horizontalOverflow: sw > iw + 1,
    scrollWidth: sw,
    overflowOffenders: offenders,
    smallTouchTargets: small,
    fonts: [...new Set([...document.querySelectorAll('h1,h2,h3,p,a,button,span,li')].slice(0, 400).map(e => getComputedStyle(e).fontFamily.split(',')[0].replace(/["']/g, '').trim()))].slice(0, 6),
    title: document.title,
    href: location.href,
  };
})()`;

const report = { url, outDir: path.resolve(outDir), shots: [] };

for (const width of widths) {
  const mobile = width < 768;
  const height = mobile ? 812 : width >= 1200 ? 900 : 1024;
  await send('Emulation.setDeviceMetricsOverride', {
    width, height, deviceScaleFactor: mobile ? 2 : 1, mobile,
    screenWidth: width, screenHeight: height,
  });
  await send('Emulation.setTouchEmulationEnabled', { enabled: mobile });
  consoleErrors.length = 0;
  failedRequests.length = 0;

  const loaded = new Promise((res) => {
    const handler = (e) => {
      const m = JSON.parse(e.data);
      if (m.method === 'Page.loadEventFired') { ws.removeEventListener('message', handler); res(); }
    };
    ws.addEventListener('message', handler);
    setTimeout(res, 15000);
  });
  const nav = await send('Page.navigate', { url });
  await loaded;
  await sleep(settle);

  const probe = await evaluate(PROBE) || {};
  // Dead-server guard (a stopped dev server produces a
  // clean-looking "This site can't be reached" page that passes every
  // mechanical check). Chrome reports the failure in the
  // navigate result and lands on chrome-error://chromewebdata/.
  const unreachable = nav.result?.errorText
    || (typeof probe.href === 'string' && probe.href.startsWith('chrome-error://') ? 'chrome-error page' : null);
  const foldPath = path.join(outDir, `shot-${width}.png`);
  const shot = await send('Page.captureScreenshot', { format: 'png' });
  fs.writeFileSync(foldPath, Buffer.from(shot.result.data, 'base64'));
  let fullPath = null;
  if (full && probe.documentHeight > height) {
    fullPath = path.join(outDir, `shot-${width}-full.png`);
    const docH = Math.min(probe.documentHeight, 8000);
    const fullShot = await send('Page.captureScreenshot', {
      format: 'png',
      captureBeyondViewport: true,
      clip: { x: 0, y: 0, width, height: docH, scale: 1 },
    });
    fs.writeFileSync(fullPath, Buffer.from(fullShot.result.data, 'base64'));
  }

  const entry = {
    width,
    mobileEmulation: mobile,
    png: path.resolve(foldPath),
    pngFull: fullPath ? path.resolve(fullPath) : null,
    viewportTruth: {
      innerWidth: probe.innerWidth,
      devicePixelRatio: probe.devicePixelRatio,
      mqMaxWidth768: probe.mqMaxWidth768,
      mqMaxWidth480: probe.mqMaxWidth480,
      trusted: probe.innerWidth === width,
    },
    horizontalOverflow: probe.horizontalOverflow,
    overflowOffenders: probe.overflowOffenders || [],
    smallTouchTargets: mobile ? (probe.smallTouchTargets || []) : [],
    fonts: probe.fonts || [],
    consoleErrors: [...consoleErrors],
    failedRequests: [...new Set(failedRequests)],
    documentHeight: probe.documentHeight,
    title: probe.title,
    unreachable: unreachable || null,
  };
  report.shots.push(entry);
  log(`${width}px: innerWidth=${probe.innerWidth} overflow=${probe.horizontalOverflow} smallTargets=${entry.smallTouchTargets.length} consoleErrors=${consoleErrors.length}${unreachable ? ` UNREACHABLE(${unreachable})` : ''} -> ${foldPath}`);
}

ws.close();
clearTimeout(timer);
await cleanup();

const anyUnreachable = report.shots.some((s) => s.unreachable);
report.unreachable = anyUnreachable;

if (!jsonOnly) {
  process.stderr.write('\n');
  for (const s of report.shots) {
    const flags = [];
    if (s.unreachable) flags.push(`UNREACHABLE: ${s.unreachable} (dead server? PNG is a Chrome error page, do not grade it)`);
    if (!s.viewportTruth.trusted) flags.push('VIEWPORT NOT TRUSTED');
    if (s.horizontalOverflow) flags.push('HORIZONTAL OVERFLOW');
    if (s.smallTouchTargets.length) flags.push(`${s.smallTouchTargets.length} touch targets < 44px`);
    if (s.consoleErrors.length) flags.push(`${s.consoleErrors.length} console errors`);
    if (s.failedRequests.length) flags.push(`${s.failedRequests.length} failed requests`);
    process.stderr.write(`[shot] ${s.width}px ${flags.length ? flags.join(' | ') : 'clean'}\n`);
  }
}
process.stdout.write(JSON.stringify(report, null, 1) + '\n');
process.exit(anyUnreachable ? 4 : 0);
