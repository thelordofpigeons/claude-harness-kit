"""
brain-nightly.py: the one job that keeps the memory folder fresh.

Run nightly from cron or Windows Task Scheduler:
  1. RECENT.md   <- sessions from the last 7 days (open threads + decisions)
  2. INSIGHTS.md <- one entry per insight file
  3. Basic Memory index refresh (runs bm-index.py if `basic-memory` is on PATH)
  4. if unpromoted session checkpoints older than 2h exist, run
     `claude -p /promote-sessions` headless on a cheap model, in bounded rounds
     (skipped with --no-promote)

Memory folder: $BRAIN_DIR, default ~/brain.
Writes only: RECENT.md, INSIGHTS.md, logs/nightly-*.log inside the memory folder.
Usage: python brain-nightly.py [--no-promote] [--no-sync]
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

BRAIN = Path(os.environ.get("BRAIN_DIR") or (Path.home() / "brain"))
SESSIONS = BRAIN / "sessions"
INSIGHTS = BRAIN / "insights"
CHECKPOINTS = BRAIN / "session-checkpoints"
LOGS = BRAIN / "logs"


def log(msg: str) -> None:
    line = f"[{datetime.now():%H:%M:%S}] {msg}"
    print(line, flush=True)
    LOGS.mkdir(parents=True, exist_ok=True)
    with (LOGS / f"nightly-{date.today():%Y-%m-%d}.log").open("a", encoding="utf-8") as fh:
        fh.write(line + "\n")


# ---------- RECENT.md ----------
def _section(text: str, header_regex: str) -> list[str]:
    # [ \t]*\n and ^## keep an empty section from swallowing the next one
    m = re.search(header_regex + r"[ \t]*\n(.*?)(?=^## |\Z)", text, re.DOTALL | re.IGNORECASE | re.MULTILINE)
    if not m:
        return []
    return [ln.strip()[2:].strip() for ln in m.group(1).splitlines() if ln.strip().startswith("- ")]


def parse_session(text: str) -> dict:
    d = re.search(r"^date:\s*(\d{4}-\d{2}-\d{2})", text, re.MULTILINE)
    return {
        "date": d.group(1) if d else None,
        "threads": _section(text, r"## Open threads"),
        "decisions": _section(text, r"## Decisions?(?: made)?[^\n]*"),
    }


def write_recent(today: date | None = None) -> int:
    today = today or date.today()
    cutoff = today - timedelta(days=7)
    parsed = []
    for f in sorted(SESSIONS.glob("*.md"), reverse=True):
        try:
            p = parse_session(f.read_text(encoding="utf-8", errors="ignore"))
            if p["date"] and date.fromisoformat(p["date"]) >= cutoff:
                parsed.append(p)
        except (ValueError, OSError):
            continue
    lines = ["# Recent (last 7 days)", ""]
    if not parsed:
        lines.append("_No sessions in the last 7 days._")
    else:
        seen: set[str] = set()
        threads = [(p["date"], t) for p in parsed for t in p["threads"] if t and not (t in seen or seen.add(t))]
        decisions = [(p["date"], d) for p in parsed for d in p["decisions"] if d]
        if threads:
            lines += ["## Open Threads"] + [f"- [{d}] {t}" for d, t in threads[:10]] + [""]
        if decisions:
            lines += ["## Recent Decisions"] + [f"- [{d}] {t}" for d, t in decisions[:10]] + [""]
    BRAIN.mkdir(parents=True, exist_ok=True)
    (BRAIN / "RECENT.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return len(parsed)


# ---------- INSIGHTS.md ----------
def parse_insight(text: str) -> dict:
    topic = re.search(r"^topic:\s*(\S+)", text, re.MULTILINE)
    conf = re.search(r"^confidence:\s*(\S+)", text, re.MULTILINE)
    pat = re.search(r"## Pattern\s*/\s*Decision[ \t]*\n(.*?)(?=^## |\Z)", text, re.DOTALL | re.IGNORECASE | re.MULTILINE)
    first = None
    if pat:
        body = [ln.strip() for ln in pat.group(1).splitlines() if ln.strip()]
        first = body[0] if body else None
    return {"topic": topic.group(1) if topic else None, "confidence": conf.group(1) if conf else "medium", "pattern": first}


def write_insights() -> int:
    items = []
    for f in sorted(INSIGHTS.glob("*.md"), reverse=True):
        try:
            p = parse_insight(f.read_text(encoding="utf-8", errors="ignore"))
        except OSError:
            continue
        if p["topic"]:
            items.append(p)
        else:
            log(f"WARNING: {f.name} has no topic field, skipped")
    lines = ["# Insights", ""]
    if not items:
        lines += ["_No insights recorded yet._", "", "> Add insights to: insights/YYYY-MM-DD-slug.md"]
    for it in items:
        lines.append(f"## {it['topic']} [{it['confidence']}]")
        if it["pattern"]:
            lines.append(it["pattern"])
        lines.append("")
    BRAIN.mkdir(parents=True, exist_ok=True)
    (BRAIN / "INSIGHTS.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return len(items)


# ---------- Basic Memory ----------
def basic_memory_sync() -> None:
    """Basic Memory 0.23 has no CLI sync; bm-index.py runs its MCP server until the index settles."""
    script = Path(__file__).with_name("bm-index.py")
    if not script.exists():
        script = BRAIN / "bm-index.py"
    if not shutil.which("basic-memory") or not script.exists():
        log("basic-memory or bm-index.py missing, skipping index refresh")
        return
    t0 = time.time()
    r = subprocess.run([sys.executable, str(script), "--max-minutes", "20"], capture_output=True, text=True, timeout=1500)
    tail = (r.stdout + r.stderr).strip().splitlines()[-2:]
    log(f"basic-memory index exit {r.returncode} in {time.time()-t0:.0f}s :: " + " | ".join(tail))


# ---------- orphaned checkpoints ----------
def orphan_count() -> int:
    if not CHECKPOINTS.is_dir():
        return 0
    cut = datetime.now(timezone.utc) - timedelta(hours=2)
    n = 0
    for f in CHECKPOINTS.glob("*.json"):
        try:
            j = json.loads(f.read_text(encoding="utf-8"))
            ts = datetime.fromisoformat(str(j.get("last_active", "")).replace("Z", "+00:00"))
            if ts < cut:
                n += 1
        except (ValueError, OSError, json.JSONDecodeError):
            continue
    return n


MAX_PROMOTE_ROUNDS = 5   # bounded cost per night; the backlog drains over a few nights


def promote_sessions() -> None:
    """Drain orphaned checkpoints, a few per night.

    One headless `/promote-sessions` call promotes one orphan and returns (observed: one
    call, one orphan). So call it repeatedly and stop on the first round that makes no
    progress: that means a checkpoint is stuck, and retrying it forever would burn tokens
    every night for nothing.
    """
    exe = shutil.which("claude")
    if not exe:
        log("claude CLI not on PATH, cannot promote")
        return
    for rnd in range(1, MAX_PROMOTE_ROUNDS + 1):
        before = orphan_count()
        if before == 0:
            break
        t0 = time.time()
        try:
            r = subprocess.run(
                [exe, "-p", "/promote-sessions", "--model", "haiku", "--permission-mode", "acceptEdits"],
                capture_output=True, text=True, timeout=1500, cwd=str(Path.home()),
            )
        except subprocess.TimeoutExpired:
            log(f"promote round {rnd}: timed out after 25min, stopping")
            return
        after = orphan_count()
        log(f"promote round {rnd}: exit {r.returncode} in {time.time()-t0:.0f}s; orphans {before} -> {after}")
        if r.returncode != 0:
            log("  stderr: " + r.stderr.strip()[-300:])
            return
        if after >= before:
            log(f"  no progress, stopping (checkpoint likely stuck; {after} left for manual review)")
            return
    log(f"promote done; {orphan_count()} orphan(s) remain")


def main(argv: list[str]) -> int:
    log("nightly start")
    n_s = write_recent()
    log(f"RECENT.md from {n_s} session(s) in the last 7 days")
    n_i = write_insights()
    log(f"INSIGHTS.md from {n_i} insight(s)")
    if "--no-sync" not in argv:
        basic_memory_sync()
    orphans = orphan_count()
    if orphans and "--no-promote" not in argv:
        log(f"{orphans} orphaned checkpoint(s), running /promote-sessions")
        promote_sessions()
    else:
        log(f"{orphans} orphaned checkpoint(s), no promotion run")
    log("nightly done")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
