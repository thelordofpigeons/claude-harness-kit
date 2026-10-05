"""
bm-index.py: refresh the Basic Memory index for the `brain` project without a Claude session.

Depends on the open-source Basic Memory tool (written against version 0.23). That version
indexes files from inside its MCP server process (watch service), not from a CLI command.
So: start `basic-memory mcp` (stdio, idle), poll the SQLite index until the entity count
stops changing, then stop the server. Idempotent; safe to run nightly.

The project name defaults to `brain`; override with BM_PROJECT. The SQLite index is read
from ~/.basic-memory/memory.db, a layout specific to that version.

Usage: python bm-index.py [--max-minutes 20] [--settle-seconds 90] [--dry-run]
       python bm-index.py --help
A real run reads the live index in ~/.basic-memory/memory.db and starts a Basic Memory
server process for the project, so it touches your actual index. --dry-run prints what
would be used (database path, project, executable) and exits without reading or starting
anything. Unknown arguments are an error, never an implicit real run.
Exit 0 on success, 1 if the server died or never produced entities, 2 on bad arguments.
"""
from __future__ import annotations

import argparse
import os
import shutil
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

DB = Path.home() / ".basic-memory" / "memory.db"
PROJECT = os.environ.get("BM_PROJECT", "brain")


def counts() -> tuple[int, int]:
    try:
        c = sqlite3.connect(f"file:{DB.as_posix()}?mode=ro", uri=True, timeout=5)
        e = c.execute("select count(*) from entity").fetchone()[0]
        r = c.execute("select count(*) from relation").fetchone()[0]
        c.close()
        return e, r
    except sqlite3.Error:
        return -1, -1


def parse_args(argv: list[str]) -> argparse.Namespace:
    ap = argparse.ArgumentParser(
        description="Refresh the Basic Memory index for one project. A real run reads "
        f"{DB} and starts a basic-memory server process; use --dry-run to inspect first.",
    )
    ap.add_argument("--max-minutes", type=float, default=20.0, help="upper bound for the whole run")
    ap.add_argument("--settle-seconds", type=float, default=90.0, help="quiet period that counts as done")
    ap.add_argument("--dry-run", action="store_true", help="print the configuration and exit; touch nothing")
    return ap.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    max_minutes, settle = args.max_minutes, args.settle_seconds
    exe = shutil.which("basic-memory")
    if args.dry_run:
        print(f"[bm-index] dry run: database={DB} project={PROJECT} executable={exe or 'NOT FOUND'}")
        print("[bm-index] dry run: nothing read, nothing started")
        return 0
    if not exe:
        print("[bm-index] basic-memory not on PATH")
        return 1
    e0, r0 = counts()
    print(f"[bm-index] before: {e0} entities, {r0} relations")
    proc = subprocess.Popen(
        [exe, "mcp", "--transport", "stdio", "--project", PROJECT],
        stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    t0 = time.time()
    last = counts()
    last_change = time.time()
    try:
        while time.time() - t0 < max_minutes * 60:
            time.sleep(10)
            if proc.poll() is not None:
                print(f"[bm-index] server exited early with code {proc.returncode}")
                return 1
            now = counts()
            if now != last:
                last, last_change = now, time.time()
                print(f"[bm-index] {int(time.time()-t0)}s: {now[0]} entities, {now[1]} relations")
            elif now[0] > 0 and time.time() - last_change > settle:
                break
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            proc.kill()
    e1, r1 = counts()
    print(f"[bm-index] after: {e1} entities, {r1} relations in {int(time.time()-t0)}s")
    return 0 if e1 > 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
