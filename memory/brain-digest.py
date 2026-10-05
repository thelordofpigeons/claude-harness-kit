"""
brain-digest.py: weekly harness health digest. Answers one question:
"is the setup actually being used, and did anything go stale?"

Sources (read-only): <BRAIN_DIR>/sessions, insights, session-checkpoints, telos, and
<CLAUDE_DIR>/projects/**/*.jsonl (transcripts modified in the window).
Writes only: <BRAIN_DIR>/digests/YYYY-Www.md (ISO year and week), and prints the same
body to stdout. Nothing pushes it anywhere; you read the file.

Environment: BRAIN_DIR (default ~/brain), CLAUDE_DIR (default ~/.claude).

Privacy note: this script reads full transcripts to count tool calls. The digest it writes
names the skills, MCP servers and subagents you actually use. Treat a real digest as
private and never publish one.

Usage: python brain-digest.py [--days 7]
"""
from __future__ import annotations

import json
import os
import re
import sys
from collections import Counter
from datetime import date, datetime, timedelta
from pathlib import Path

HOME = Path.home()
BRAIN = Path(os.environ.get("BRAIN_DIR") or (HOME / "brain"))
CLAUDE = Path(os.environ.get("CLAUDE_DIR") or (HOME / ".claude"))
PROJECTS = CLAUDE / "projects"
DIGESTS = BRAIN / "digests"

CADENCE_DAYS = {"stable": 90, "changing": 30, "volatile": 7}


def files_since(root: Path, pattern: str, since: datetime) -> list[Path]:
    out = []
    if not root.exists():
        return out
    for f in root.rglob(pattern):
        try:
            if datetime.fromtimestamp(f.stat().st_mtime) >= since:
                out.append(f)
        except OSError:
            continue
    return out


def scan_transcripts(since: datetime) -> dict:
    """Count skill invocations, memory reads, MCP servers and subagents in recent transcripts.
    Line-based: each JSONL line is one event; we only look at tool_use blocks."""
    skills, mcp, agents = Counter(), Counter(), Counter()
    memory_reads, brain_reads, tool_calls, lines_seen = 0, 0, 0, 0
    for f in files_since(PROJECTS, "*.jsonl", since):
        try:
            with f.open(encoding="utf-8", errors="ignore") as fh:
                for line in fh:
                    lines_seen += 1
                    if '"tool_use"' not in line:
                        continue
                    try:
                        ev = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    content = (ev.get("message") or {}).get("content") or []
                    if not isinstance(content, list):
                        continue
                    for block in content:
                        if not isinstance(block, dict) or block.get("type") != "tool_use":
                            continue
                        tool_calls += 1
                        name = str(block.get("name", ""))
                        inp = block.get("input") or {}
                        if name == "Skill":
                            skills[str(inp.get("skill", "?"))] += 1
                        elif name.startswith("mcp__"):
                            mcp[name.split("__")[1]] += 1
                        elif name == "Agent":
                            agents[str(inp.get("subagent_type", "general"))] += 1
                        elif name == "Read":
                            fp = str(inp.get("file_path", "")).replace(chr(92), "/")
                            if "/memory/" in fp:
                                memory_reads += 1
                            if "/brain/" in fp:
                                brain_reads += 1
        except OSError:
            continue
    return {
        "skills": skills, "mcp": mcp, "agents": agents, "memory_reads": memory_reads,
        "brain_reads": brain_reads, "tool_calls": tool_calls, "lines": lines_seen,
    }


def telos_overdue(today: date | None = None) -> list[str]:
    """TELOS files past their review cadence (stable 90d, changing 30d, volatile 7d)."""
    today = today or date.today()
    out = []
    telos = BRAIN / "telos"
    if not telos.is_dir():
        return out
    for f in telos.glob("*.md"):
        head = f.read_text(encoding="utf-8", errors="ignore")[:600]
        s = re.search(r"^stability:\s*(\w+)", head, re.MULTILINE)
        r = re.search(r"^last_reviewed:\s*(\d{4}-\d{2}-\d{2})", head, re.MULTILINE)
        if s and r and s.group(1) in CADENCE_DAYS:
            age = (today - date.fromisoformat(r.group(1))).days
            if age > CADENCE_DAYS[s.group(1)]:
                out.append(f"{f.stem} ({age}d, cadence {CADENCE_DAYS[s.group(1)]}d)")
    return sorted(out)


def top(counter: Counter, n: int = 8) -> str:
    if not counter:
        return "- none"
    return "\n".join(f"- {k}: {v}" for k, v in counter.most_common(n))


def main(argv: list[str]) -> int:
    days = 7
    if "--days" in argv:
        days = int(argv[argv.index("--days") + 1])
    since = datetime.now() - timedelta(days=days)
    today = date.today()

    sessions = files_since(BRAIN / "sessions", "*.md", since)
    insights = files_since(BRAIN / "insights", "*.md", since)
    decisions = 0
    for f in sessions:
        t = f.read_text(encoding="utf-8", errors="ignore")
        m = re.search(r"## Decisions?[^\n]*\n(.*?)(?=^## |\Z)", t, re.DOTALL | re.IGNORECASE | re.MULTILINE)
        if m:
            decisions += sum(1 for ln in m.group(1).splitlines() if ln.strip().startswith("- "))
    ckpt_dir = BRAIN / "session-checkpoints"
    orphans = len(list(ckpt_dir.glob("*.json"))) if ckpt_dir.exists() else 0
    processed = len(files_since(ckpt_dir / "processed", "*.json", since))
    tr = scan_transcripts(since)
    overdue = telos_overdue(today)

    week = today.isocalendar()
    out = DIGESTS / f"{week[0]}-W{week[1]:02d}.md"
    DIGESTS.mkdir(parents=True, exist_ok=True)
    body = f"""---
type: digest
date: {today}
window_days: {days}
---
# Harness digest, week {week[1]} ({(today - timedelta(days=days))} to {today})

## Output
- Session notes written: {len(sessions)}
- Decisions recorded: {decisions}
- Insights added: {len(insights)}
- Checkpoints promoted: {processed}; still unpromoted: {orphans}

## Was the harness used?
- Tool calls seen in transcripts: {tr['tool_calls']} (over {tr['lines']} transcript lines)
- Memory-file reads: {tr['memory_reads']}; brain-file reads: {tr['brain_reads']}

### Skills invoked
{top(tr['skills'])}

### MCP servers used
{top(tr['mcp'])}

### Subagents spawned
{top(tr['agents'])}

## Stale
- TELOS past review cadence: {', '.join(overdue) if overdue else 'none'}

## Read this as
A skill or MCP server with zero calls for four consecutive digests is a candidate for removal.
Memory reads at zero means memory files are loaded but never followed into a note.
"""
    out.write_text(body, encoding="utf-8")
    print(body)
    print(f"[digest] written {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
