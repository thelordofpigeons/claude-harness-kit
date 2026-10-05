#!/usr/bin/env node
/**
 * statusline.mjs: Claude Code status line (Node.js, zero dependencies).
 * TEMPLATE: the status names below (STATUS_COLORS) are an example lifecycle;
 * parameters HARNESS_TASK_FILE (base task file, default ~/.claude/current-task),
 * CLAUDE_HOME (default ~/.claude), STATUSLINE_STATUS_COLORS (path to a JSON file
 * mapping STATUS -> color name, overrides the example map).
 *
 * Reads JSON from stdin (Claude Code session data) and the companion files that
 * scripts/task-state.sh writes next to the task file.
 *
 * LINE 1: Task Name #ID  * STATUS  -----O.....  5/12  due 3d  stale 2d
 * LINE 2: [model]  [block bar]  42%  $0.18 ($1.24 today)  14m 7s  +312/-47  git:main  gates 3/4  done 3/7d
 *
 * There is no network access and no credential access in this file. It writes
 * only the per-session cost files under <claude home>/daily-cost/.
 */

import { createInterface } from 'readline';
import { readFileSync, existsSync, readdirSync, writeFileSync, mkdirSync } from 'fs';
import { join, dirname } from 'path';
import { execSync } from 'child_process';

// ANSI colors
const RED     = '\x1b[31m';
const YELLOW  = '\x1b[33m';
const GREEN   = '\x1b[32m';
const BLUE    = '\x1b[34m';
const CYAN    = '\x1b[36m';
const MAGENTA = '\x1b[35m';
const DIM     = '\x1b[2m';
const BOLD    = '\x1b[1m';
const RESET   = '\x1b[0m';
const COLOR_BY_NAME = { red: RED, yellow: YELLOW, green: GREEN, blue: BLUE, cyan: CYAN, magenta: MAGENTA, dim: DIM };

// Helpers
const HOME = process.env.HOME || process.env.USERPROFILE || '';
const claudeDir = process.env.CLAUDE_HOME || join(HOME, '.claude');
const taskBase = process.env.HARNESS_TASK_FILE || join(claudeDir, 'current-task');

function readFile(path) {
  try { return existsSync(path) ? readFileSync(path, 'utf8').trim().replace(/\r/g, '') : ''; }
  catch { return ''; }
}

function get(obj, path, def = '') {
  try {
    const v = path.split('.').reduce((o, k) => o?.[k], obj);
    return v != null ? v : def;
  } catch { return def; }
}

// Read stdin
const rl = createInterface({ input: process.stdin });
let raw = '';
rl.on('line', l => raw += l);
rl.on('close', () => {
  let d = {};
  try { d = JSON.parse(raw); } catch { /* use defaults */ }

  // Session data
  const model      = get(d, 'model.display_name', 'Claude');
  const ctxPct     = Math.floor(get(d, 'context_window.used_percentage', 0));
  const costUsd    = parseFloat(get(d, 'cost.total_cost_usd', 0)) || 0;
  const durationMs = parseInt(get(d, 'cost.total_duration_ms', 0)) || 0;
  const linesAdd   = parseInt(get(d, 'cost.total_lines_added', 0)) || 0;
  const linesDel   = parseInt(get(d, 'cost.total_lines_removed', 0)) || 0;
  const cwd        = get(d, 'workspace.current_dir') || get(d, 'cwd', '');
  const sessionId  = get(d, 'session_id', '');

  // Active task state (written by scripts/task-state.sh)
  const taskId     = readFile(taskBase);
  const taskName   = readFile(taskBase + '-name').split('\n')[0];
  const taskStatus = readFile(taskBase + '-status');
  const taskStep   = readFile(taskBase + '-step');
  const taskDue    = readFile(taskBase + '-due');
  const taskStart  = readFile(taskBase + '-start');

  // Daily cost tracking: one small file per session, summed for the day
  const today = new Date().toISOString().slice(0, 10);
  const dailyCostDir = join(claudeDir, 'daily-cost', today);
  let dailyCost = costUsd;
  try {
    if (sessionId) {
      const sessionFile = join(dailyCostDir, sessionId.replace(/[^a-z0-9-]/gi, '_'));
      try {
        mkdirSync(dailyCostDir, { recursive: true });
        writeFileSync(sessionFile, String(costUsd), 'utf8');
      } catch { /* ignore write errors */ }
    }
    if (existsSync(dailyCostDir)) {
      dailyCost = readdirSync(dailyCostDir).reduce((sum, f) => {
        return sum + (parseFloat(readFile(join(dailyCostDir, f))) || 0);
      }, 0);
    }
  } catch { dailyCost = costUsd; }

  // Throughput: tasks shipped in the last 7 days (task-state.sh shipped appends to shipped-log)
  const shippedLog = join(dirname(taskBase), 'shipped-log');
  let shippedCount = 0;
  if (existsSync(shippedLog)) {
    const cutoff = Date.now() - 7 * 24 * 60 * 60 * 1000;
    shippedCount = readFile(shippedLog).split('\n').filter(line => {
      const ts = line.split('|')[0];
      if (!ts) return false;
      return new Date(ts).getTime() > cutoff;
    }).length;
  }

  // Workflow quality gates, derived from the step number
  const STEP_MAP = {
    design: 1, plan: 2, task_created: 3, tests: 4,
    implement: 5, review: 6, security: 7, committed: 8,
    in_review: 9, docs: 10, testing: 11, shipped: 12
  };
  const stepNum = STEP_MAP[taskStep] || 0;
  // Gates: tests (step 4), review (step 6), security (step 7), docs (step 10)
  const gatesHit = [4, 6, 7, 10].filter(g => stepNum >= g).length;
  const gatesTotal = 4;

  // Stale task alert
  let staleDays = 0;
  if (taskStart && taskId) {
    const startMs = new Date(taskStart).getTime();
    if (!isNaN(startMs)) {
      staleDays = Math.floor((Date.now() - startMs) / (24 * 60 * 60 * 1000));
    }
  }

  // Due date countdown
  let daysLeft = null;
  if (taskDue) {
    const dueMs = new Date(taskDue).getTime();
    if (!isNaN(dueMs)) {
      daysLeft = Math.ceil((dueMs - Date.now()) / (24 * 60 * 60 * 1000));
    }
  }

  // Fallback date: not every task carries a due date, so when there is no
  // countdown to show, fall back to when the task was started.
  let startLabel = '';
  if (taskStart) {
    const startDate = new Date(taskStart);
    if (!isNaN(startDate.getTime())) {
      startLabel = startDate.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
    }
  }

  // Git branch
  let gitBranch = '';
  try {
    const gitDir = cwd || process.cwd();
    gitBranch = execSync(`git -C "${gitDir}" branch --show-current`, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch { gitBranch = ''; }

  // Context bar (12 chars wide)
  const ctxFilled = Math.min(Math.floor(ctxPct * 12 / 100), 12);
  const ctxEmpty  = 12 - ctxFilled;
  const ctxBar    = '\u2593'.repeat(ctxFilled) + '\u2591'.repeat(ctxEmpty);
  const ctxColor  = ctxPct >= 85 ? RED : ctxPct >= 65 ? YELLOW : GREEN;
  const ctxCritical = ctxPct >= 85;

  // Model shortname
  const modelShort = model.replace(/[Cc]laude[-_ ]*/g, '').slice(0, 14);

  // Cost formatting
  const costFmt      = '$' + costUsd.toFixed(2);
  const dailyCostFmt = '$' + dailyCost.toFixed(2);
  const costColor    = costUsd >= 5 ? RED : costUsd >= 1 ? YELLOW : GREEN;

  // Duration
  const secs     = Math.floor(durationMs / 1000);
  const mins     = Math.floor(secs / 60);
  const secsRem  = secs % 60;
  const timeColor = mins >= 120 ? RED : mins >= 45 ? YELLOW : CYAN;

  // Status color. EXAMPLE lifecycle; replace the keys with your tracker's
  // statuses, or point STATUSLINE_STATUS_COLORS at a JSON file such as
  // {"DOING": "green", "DONE": "cyan"} (names: red yellow green blue cyan magenta dim).
  let STATUS_COLORS = {
    'DOING': GREEN,
    'REVIEW': BLUE,
    'VERIFY': YELLOW,
    'DONE': CYAN,
    'TODO': MAGENTA
  };
  try {
    const custom = process.env.STATUSLINE_STATUS_COLORS;
    if (custom && existsSync(custom)) {
      const parsed = JSON.parse(readFileSync(custom, 'utf8'));
      STATUS_COLORS = {};
      for (const [k, v] of Object.entries(parsed)) STATUS_COLORS[k.toUpperCase()] = COLOR_BY_NAME[String(v).toLowerCase()] || DIM;
    }
  } catch { /* keep the example map */ }
  const statusColor = STATUS_COLORS[taskStatus.replace(/\s+/g, ' ').toUpperCase()] || DIM;

  // Step progress bar
  const STEP_TOTAL = 12;
  let stepBar = '';
  if (stepNum > 0) {
    for (let i = 1; i <= STEP_TOTAL; i++) {
      if (i < stepNum)        stepBar += `${DIM}\u2500${RESET}`;
      else if (i === stepNum) stepBar += `${GREEN}\u25C6${RESET}`;
      else                    stepBar += `${DIM}\u00B7${RESET}`;
    }
  }

  // LINE 1: task info
  let line1 = '';
  if (taskId) {
    let displayName = taskName || taskId;
    if (displayName.length > 34) displayName = displayName.slice(0, 32) + '..';

    line1 = `${BOLD}${displayName}${RESET}`;
    line1 += ` ${DIM}#${taskId}${RESET}`;

    if (taskStatus) {
      line1 += `  ${statusColor}* ${taskStatus}${RESET}`;
    }

    if (stepNum > 0) {
      line1 += `  ${stepBar} ${DIM}${stepNum}/${STEP_TOTAL}${RESET}`;
    }

    if (daysLeft !== null) {
      if (daysLeft < 0) {
        line1 += `  ${RED}overdue ${Math.abs(daysLeft)}d${RESET}`;
      } else if (daysLeft <= 2) {
        line1 += `  ${RED}due ${daysLeft}d${RESET}`;
      } else if (daysLeft <= 5) {
        line1 += `  ${YELLOW}due ${daysLeft}d${RESET}`;
      } else {
        line1 += `  ${DIM}due ${daysLeft}d${RESET}`;
      }
    } else if (startLabel) {
      line1 += `  ${DIM}started ${startLabel}${RESET}`;
    }

    if (staleDays > 3) {
      line1 += `  ${YELLOW}stale ${staleDays}d${RESET}`;
    }
  } else {
    line1 = `${YELLOW}no active task${RESET}  ${DIM}${basenameOf(cwd)}${RESET}`;
  }

  // LINE 2: session health metrics
  let line2 = '';

  if (ctxCritical) {
    line2 = `${RED}${BOLD}CONTEXT ${ctxPct}%: run /compact now${RESET}`;
    line2 += `  ${DIM}[${modelShort}]${RESET}`;
    line2 += `  ${costColor}${costFmt}${RESET}`;
    if (dailyCost > costUsd + 0.01) {
      line2 += ` ${DIM}(${dailyCostFmt} today)${RESET}`;
    }
  } else {
    line2 = `${DIM}[${modelShort}]${RESET}`;
    line2 += `  ${ctxColor}${ctxBar}${RESET} ${ctxPct}%`;
    line2 += `  ${costColor}${costFmt}${RESET}`;
    if (dailyCost > costUsd + 0.01) {
      line2 += ` ${DIM}(${dailyCostFmt} today)${RESET}`;
    }
  }

  line2 += `  ${timeColor}${mins}m ${secsRem}s${RESET}`;

  if (linesAdd > 0 || linesDel > 0) {
    line2 += `  ${GREEN}+${linesAdd}${RESET}/${RED}-${linesDel}${RESET}`;
  }

  if (gitBranch) {
    line2 += `  ${DIM}git:${gitBranch}${RESET}`;
  }

  // Quality gates (only show when a task is active and past task_created)
  if (taskId && stepNum >= 3) {
    const gateColor = gatesHit >= 3 ? GREEN : gatesHit >= 2 ? YELLOW : RED;
    line2 += `  ${gateColor}gates ${gatesHit}/${gatesTotal}${RESET}`;
  }

  if (shippedCount > 0) {
    line2 += `  ${GREEN}done ${shippedCount}/7d${RESET}`;
  }

  process.stdout.write(line1 + '\n' + line2 + '\n');
});

function basenameOf(p) {
  if (!p) return '';
  return p.replace(/\\/g, '/').split('/').filter(Boolean).pop() || '';
}
