// SessionStart hook: announce scheduled audit results once per audit run.
// Compares report mtimes in ~/.claude/logs/ against a marker; on new results,
// emits systemMessage (user-visible) + additionalContext (model-visible), then
// advances the marker so the announcement fires only once.
import fs from 'node:fs'
import path from 'node:path'
import os from 'node:os'

const logs = path.join(os.homedir(), '.claude', 'logs')
const marker = path.join(logs, '.audit-announced')
const reports = [
  { label: 'branch-divergence', file: path.join(logs, 'branch-divergence-latest.txt') },
  { label: 'permissions-secrets', file: path.join(logs, 'permissions-secrets-latest.txt') },
]

let newest = 0
for (const r of reports) {
  try { newest = Math.max(newest, fs.statSync(r.file).mtimeMs) } catch {}
}
if (!newest) process.exit(0)

let last = 0
try { last = Number(fs.readFileSync(marker, 'utf8')) || 0 } catch {}
if (newest <= last) process.exit(0)

const lines = []
for (const r of reports) {
  let text = ''
  try { text = fs.readFileSync(r.file, 'utf8') } catch { continue }
  const interesting = text.split(/\r?\n/).filter(l => /^(DIVERGED|KNOWN|SUSPECT|WARN|RESULT)/.test(l))
  lines.push(`[${r.label}] ${interesting.join(' | ') || 'no summary lines'}`)
}

fs.writeFileSync(marker, String(newest))

const summary = lines.join('\n')
const clean = !/DIVERGED|SUSPECT/.test(summary)
process.stdout.write(JSON.stringify({
  systemMessage: `Harness audit ran (results ${new Date(newest).toISOString().slice(0, 10)}): ${clean ? 'clean (known deferred items only)' : 'NEW FINDINGS, see below'}`,
  hookSpecificOutput: {
    hookEventName: 'SessionStart',
    additionalContext: `Scheduled audit results since last announcement:\n${summary}\nBriefly relay these audit results to the user in your next reply (new findings first; KNOWN items are deferred by design, mention only in passing). Full reports: ~/.claude/logs/*-latest.txt`,
  },
}))
