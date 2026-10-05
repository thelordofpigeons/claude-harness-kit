#!/usr/bin/env node
// WINDOWS-ONLY: relies on PowerShell (Get-CimInstance, Get-NetTCPConnection) and taskkill.
// dev-server-reaper.mjs: SessionEnd hook.
// Dry run (prints, kills nothing): node dev-server-reaper.mjs --dry-run
//
// Dev servers started from a Claude session (Bash run_in_background: `npx next
// dev`, `vite`, `tsx watch`, `npm run dev`) outlive the session and pile up:
// leftover `next dev` servers and their worker pools keep holding memory
// (several GB of commit in total) after the session that started them is gone.
//
// At session end this kills two kinds of dev-server process trees:
//   1. trees descending from the claude.exe that is ending right now
//   2. trees whose ancestry is already broken (top-most living ancestor has no
//      parent) and contains no live terminal/IDE/claude; leftovers of earlier
//      sessions that closed without this hook.
// Trees that hang off a live WindowsTerminal / VS Code / explorer / another
// claude.exe are the user's or another session's and are left alone.
//
// Skipped on reason=clear (the user is still in the terminal).
// Log: ~/.claude/logs/dev-server-reaper.log. Never crashes the hook.
//
// Install: copy to ~/.claude/hooks/ and add to settings.json SessionEnd:
//   { "type": "command", "command": "node \"$HOME/.claude/hooks/dev-server-reaper.mjs\"", "timeout": 30 }

import { execFileSync, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const DEV_SERVER = /(next(\.js)?["']?\s+dev|next-server|\bvite(\.js)?\b|tsx(\.mjs)?["']?\s+watch|nodemon|concurrently|npm(-cli\.js)?["']?\s+run\s+dev|turbopack)/i;
// Real terminal / IDE hosts only. cmd.exe, pwsh.exe, bash.exe, conhost.exe are
// NOT roots: npm and npx wrap every server in cmd.exe shims, so treating them
// as owners made an orphaned `npm run dev` tree look owned.
// A shell is "alive" only through what hosts it; if its own parent is gone, it
// is the top of an orphaned tree.
const LIVE_ROOTS = new Set(['windowsterminal.exe', 'code.exe', 'cursor.exe', 'explorer.exe', 'wt.exe', 'openconsole.exe']);

function readStdin() {
  try { return fs.readFileSync(0, 'utf8'); } catch { return ''; }
}

function log(line) {
  try {
    const dir = path.join(os.homedir(), '.claude', 'logs');
    fs.mkdirSync(dir, { recursive: true });
    fs.appendFileSync(path.join(dir, 'dev-server-reaper.log'), `${new Date().toISOString()} ${line}\n`);
  } catch {}
}

function listProcesses() {
  const ps = 'Get-CimInstance Win32_Process | Select-Object ProcessId,ParentProcessId,Name,CommandLine | ConvertTo-Json -Compress';
  const out = execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', ps], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, windowsHide: true });
  const arr = JSON.parse(out);
  const map = new Map();
  for (const p of Array.isArray(arr) ? arr : [arr]) {
    map.set(p.ProcessId, { pid: p.ProcessId, ppid: p.ParentProcessId, name: String(p.Name || '').toLowerCase(), cmd: p.CommandLine || '' });
  }
  return map;
}

// PIDs that own a listening socket with at least one established client
// connection. A Claude Bash run_in_background shell can exit while its session
// is alive and still hitting the server (a vite server can look
// orphaned by ancestry yet still have live localhost clients). "In use" beats
// "orphaned by ancestry" for every verdict except own-session.
function pidsWithActiveClients() {
  const ps = 'Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -lt 49152 } | Select-Object -ExpandProperty OwningProcess -Unique | ConvertTo-Json -Compress';
  try {
    const out = execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', ps], { encoding: 'utf8', windowsHide: true }).trim();
    if (!out) return new Set();
    const arr = JSON.parse(out);
    return new Set((Array.isArray(arr) ? arr : [arr]).map(Number));
  } catch { return new Set(); }
}

function main() {
  if (process.platform !== 'win32') return;
  let input = {};
  try { input = JSON.parse(readStdin() || '{}'); } catch {}
  if (input.reason === 'clear') return;

  const procs = listProcesses();
  const busy = pidsWithActiveClients();

  // The claude.exe ending now: walk up from this hook process.
  let selfClaude = null;
  for (let cur = procs.get(process.pid), hops = 0; cur && hops < 12; cur = procs.get(cur.ppid), hops++) {
    if (cur.name === 'claude.exe') { selfClaude = cur.pid; break; }
  }

  const toKill = new Map(); // top-most PID -> verdict; killed with /T
  for (const p of procs.values()) {
    if (p.name !== 'node.exe') continue;
    if (!DEV_SERVER.test(p.cmd)) continue;

    let cur = p, top = p, verdict = null;
    for (let hops = 0; hops < 25; hops++) {
      const parent = procs.get(cur.ppid);
      if (!parent || parent.pid === cur.pid) { verdict = 'orphan'; break; }
      if (parent.pid === selfClaude) { verdict = 'own-session'; top = cur; break; }
      if (parent.name === 'claude.exe') { verdict = 'other-session'; break; }
      if (LIVE_ROOTS.has(parent.name)) {
        // A live shell/terminal owns this tree, unless that shell is itself orphaned.
        const gp = procs.get(parent.ppid);
        if (gp && gp.pid !== parent.pid) { verdict = 'owned'; break; }
      }
      if (parent.name === 'wininit.exe' || parent.name === 'services.exe' || parent.name === 'system' || parent.pid <= 4) { verdict = 'owned'; break; }
      cur = parent; top = parent;
    }
    if (verdict === 'orphan' || verdict === 'own-session') {
      if (!toKill.has(top.pid)) toKill.set(top.pid, verdict);
    }
  }

  // Tree-level in-use check: an orphaned tree whose ANY member holds a socket
  // with live clients is somebody's server (the shell that spawned it is gone,
  // the session or the user's browser is not). Own-session trees die regardless.
  const dryRunFlag = process.env.REAPER_DRY_RUN === '1' || process.argv.includes('--dry-run');
  for (const [topPid, verdict] of [...toKill]) {
    if (verdict !== 'orphan') continue;
    const members = new Set([topPid]);
    let grew = true;
    while (grew) {
      grew = false;
      for (const q of procs.values()) if (!members.has(q.pid) && members.has(q.ppid)) { members.add(q.pid); grew = true; }
    }
    const hot = [...members].find((pid) => busy.has(pid));
    if (hot !== undefined) {
      toKill.delete(topPid);
      const msg = `skip in-use tree top=${topPid} busy_pid=${hot} cmd=${(procs.get(hot) || {}).cmd?.slice(-70)}`;
      log(msg); if (dryRunFlag) console.log(`SKIP ${msg}`);
    }
  }

  const dryRun = dryRunFlag;
  if (!toKill.size) { log('nothing to reap'); if (dryRun) console.log('nothing to reap'); return; }
  for (const [pid, verdict] of toKill) {
    const p = procs.get(pid);
    const desc = `tree pid=${pid} (${verdict}) name=${p && p.name} cmd=${(p && p.cmd || '').slice(0, 120)}`;
    if (dryRun) { console.log(`WOULD KILL ${desc}`); continue; }
    const r = spawnSync('taskkill.exe', ['/PID', String(pid), '/T', '/F'], { encoding: 'utf8', windowsHide: true });
    log(`killed ${desc} rc=${r.status}`);
  }
}

try { main(); } catch (e) { log(`error: ${e && e.message}`); }
process.exit(0);
