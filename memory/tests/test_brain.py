"""Tests for the memory scaffold scripts.

Every test runs against a fabricated memory folder in a pytest tmp dir. HOME, USERPROFILE,
BRAIN_DIR and CLAUDE_DIR all point into that tmp dir, and a guard fixture makes any read
of the real ~/brain fail the test.

Run: python -m pytest memory/tests -q
"""
from __future__ import annotations

import importlib.util
import json
import os
import sqlite3
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import pytest

MEMORY = Path(__file__).resolve().parent.parent
EXAMPLES = MEMORY / "examples"
TEMPLATES = MEMORY / "telos-templates"

# Captured before any monkeypatching, used by the guard.
REAL_BRAIN = os.path.normcase(os.path.abspath(os.path.join(os.path.expanduser("~"), "brain")))


def _under_real_brain(p) -> bool:
    return os.path.normcase(os.path.abspath(str(p))).startswith(REAL_BRAIN)


@pytest.fixture()
def sandbox(tmp_path, monkeypatch):
    home = tmp_path / "home"
    brain = tmp_path / "brain"
    claude = tmp_path / "claude"
    for d in (home, brain, claude):
        d.mkdir()
    for name in ("sessions", "insights", "session-checkpoints", "telos"):
        (brain / name).mkdir()
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("USERPROFILE", str(home))
    monkeypatch.setenv("BRAIN_DIR", str(brain))
    monkeypatch.setenv("CLAUDE_DIR", str(claude))

    touched: list[str] = []
    for attr in ("read_text", "open", "glob", "rglob", "iterdir", "write_text"):
        orig = getattr(Path, attr)

        def make(orig=orig, attr=attr):
            def guarded(self, *a, **kw):
                if _under_real_brain(self):
                    touched.append(f"{attr}:{self}")
                    raise AssertionError(f"test touched the real brain: {attr} {self}")
                return orig(self, *a, **kw)
            return guarded
        monkeypatch.setattr(Path, attr, make())
    return {"home": home, "brain": brain, "claude": claude, "touched": touched}


def load(name: str):
    """Import a hyphenated script fresh so it picks up the sandbox environment."""
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), MEMORY / f"{name}.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def write_session(brain: Path, name: str, day: date, threads=(), decisions=()):
    body = [f"---\ntype: session\ndate: {day.isoformat()}\ntask_id: none\n---\n", "## What we built\n- a thing\n"]
    body.append("## Decisions made (with rationale)\n" + "".join(f"- {d}\n" for d in decisions))
    body.append("## Open threads\n" + "".join(f"- {t}\n" for t in threads))
    (brain / "sessions" / name).write_text("\n".join(body), encoding="utf-8")


def write_checkpoint(brain: Path, sid: str, last_active: datetime):
    data = {"session_id": sid, "transcript_path": "x.jsonl", "cwd": "d", "task_id": "none",
            "last_active": last_active.strftime("%Y-%m-%dT%H:%M:%SZ")}
    (brain / "session-checkpoints" / f"{sid}.json").write_text(json.dumps(data), encoding="utf-8")


# ---------- sandbox guard ----------
def test_modules_resolve_into_the_sandbox(sandbox):
    nightly = load("brain-nightly")
    digest = load("brain-digest")
    assert nightly.BRAIN == sandbox["brain"]
    assert digest.BRAIN == sandbox["brain"]
    assert digest.PROJECTS == sandbox["claude"] / "projects"
    assert not _under_real_brain(nightly.BRAIN)


def test_guard_trips_on_real_brain(sandbox):
    with pytest.raises(AssertionError):
        Path(REAL_BRAIN).glob("*.md").__next__()


def test_default_brain_follows_home_when_env_unset(sandbox, monkeypatch):
    monkeypatch.delenv("BRAIN_DIR")
    nightly = load("brain-nightly")
    assert nightly.BRAIN == sandbox["home"] / "brain"


# ---------- parse_session / parse_insight ----------
def test_parse_session_on_shipped_example(sandbox):
    nightly = load("brain-nightly")
    p = nightly.parse_session((EXAMPLES / "session-2025-01-15-09.md").read_text(encoding="utf-8"))
    assert p["date"] == "2025-01-15"
    assert len(p["threads"]) == 2
    assert p["decisions"][0].startswith("Retry cap of 3")


def test_parse_session_without_sections(sandbox):
    nightly = load("brain-nightly")
    p = nightly.parse_session("no frontmatter here")
    assert p == {"date": None, "threads": [], "decisions": []}


def test_parse_insight_on_shipped_example(sandbox):
    nightly = load("brain-nightly")
    p = nightly.parse_insight((EXAMPLES / "insight-2025-01-15-example.md").read_text(encoding="utf-8"))
    assert p["topic"] == "bounded-retries"
    assert p["confidence"] == "medium"
    assert p["pattern"].startswith("Every retry loop")


def test_parse_insight_defaults_confidence(sandbox):
    nightly = load("brain-nightly")
    p = nightly.parse_insight("---\ntopic: x\n---\n## Pattern / Decision\nbody\n")
    assert p["confidence"] == "medium"
    assert p["pattern"] == "body"


# ---------- write_recent / write_insights ----------
def test_write_recent_keeps_only_last_7_days_and_dedups(sandbox):
    nightly = load("brain-nightly")
    today = date(2025, 1, 15)
    write_session(sandbox["brain"], "a.md", today, threads=["same thread", "only a"], decisions=["D1"])
    write_session(sandbox["brain"], "b.md", today - timedelta(days=3), threads=["same thread"], decisions=["D2"])
    write_session(sandbox["brain"], "old.md", today - timedelta(days=30), threads=["too old"], decisions=["D-old"])
    n = nightly.write_recent(today)
    text = (sandbox["brain"] / "RECENT.md").read_text(encoding="utf-8")
    assert n == 2
    assert text.count("same thread") == 1
    assert "too old" not in text and "D-old" not in text
    assert "## Open Threads" in text and "## Recent Decisions" in text


def test_write_recent_caps_at_ten(sandbox):
    nightly = load("brain-nightly")
    today = date(2025, 1, 15)
    write_session(sandbox["brain"], "a.md", today, threads=[f"t{i}" for i in range(15)])
    nightly.write_recent(today)
    text = (sandbox["brain"] / "RECENT.md").read_text(encoding="utf-8")
    assert text.count("- [2025-01-15] t") == 10


def test_write_recent_with_no_sessions(sandbox):
    nightly = load("brain-nightly")
    assert nightly.write_recent(date(2025, 1, 15)) == 0
    assert "No sessions" in (sandbox["brain"] / "RECENT.md").read_text(encoding="utf-8")


def test_write_insights_skips_notes_without_topic(sandbox):
    nightly = load("brain-nightly")
    (sandbox["brain"] / "insights" / "good.md").write_text(
        (EXAMPLES / "insight-2025-01-15-example.md").read_text(encoding="utf-8"), encoding="utf-8")
    (sandbox["brain"] / "insights" / "bad.md").write_text("no frontmatter\n", encoding="utf-8")
    assert nightly.write_insights() == 1
    text = (sandbox["brain"] / "INSIGHTS.md").read_text(encoding="utf-8")
    assert "## bounded-retries [medium]" in text


# ---------- orphan_count ----------
def test_orphan_count_only_counts_checkpoints_older_than_2h(sandbox):
    nightly = load("brain-nightly")
    now = datetime.now(timezone.utc)
    write_checkpoint(sandbox["brain"], "fresh", now - timedelta(minutes=10))
    write_checkpoint(sandbox["brain"], "old1", now - timedelta(hours=3))
    write_checkpoint(sandbox["brain"], "old2", now - timedelta(days=2))
    (sandbox["brain"] / "session-checkpoints" / "broken.json").write_text("{not json", encoding="utf-8")
    assert nightly.orphan_count() == 2


def test_orphan_count_without_checkpoint_dir(sandbox):
    nightly = load("brain-nightly")
    (sandbox["brain"] / "session-checkpoints").rmdir()
    assert nightly.orphan_count() == 0


# ---------- digest ----------
def test_telos_overdue_uses_cadence_by_stability(sandbox):
    digest = load("brain-digest")
    telos = sandbox["brain"] / "telos"
    for name, stab, reviewed in [
        ("10-identity", "stable", "2025-01-01"),     # 14 days old, cadence 90: fine
        ("20-context", "volatile", "2025-01-01"),    # 14 days old, cadence 7: overdue
        ("30-projects", "changing", "2024-11-01"),   # 75 days old, cadence 30: overdue
    ]:
        (telos / f"{name}.md").write_text(
            f"---\ntelos_section: x\nstability: {stab}\nlast_reviewed: {reviewed}\n---\n", encoding="utf-8")
    out = digest.telos_overdue(date(2025, 1, 15))
    assert any(s.startswith("20-context") for s in out)
    assert any(s.startswith("30-projects") for s in out)
    assert not any(s.startswith("10-identity") for s in out)


def test_telos_templates_are_valid_and_carry_required_keys(sandbox):
    keys = ("telos_section", "sensitivity", "stability", "last_reviewed")
    files = sorted(TEMPLATES.glob("[0-9][0-9]-*.md"))
    assert len(files) == 10
    for f in files:
        head = f.read_text(encoding="utf-8").split("---")[1]
        for k in keys:
            assert f"\n{k}:" in "\n" + head, f"{f.name} lacks {k}"


def test_scan_transcripts_counts_tool_use(sandbox):
    digest = load("brain-digest")
    proj = sandbox["claude"] / "projects" / "p1"
    proj.mkdir(parents=True)

    def ev(*blocks):
        return json.dumps({"message": {"content": list(blocks)}})
    lines = [
        ev({"type": "tool_use", "name": "Skill", "input": {"skill": "recall"}}),
        ev({"type": "tool_use", "name": "Skill", "input": {"skill": "recall"}},
           {"type": "tool_use", "name": "mcp__demo__lookup", "input": {}}),
        ev({"type": "tool_use", "name": "Agent", "input": {"subagent_type": "reviewer"}}),
        ev({"type": "tool_use", "name": "Read", "input": {"file_path": "/x/brain/telos/10-identity.md"}}),
        "not json but mentions \"tool_use\"",
        json.dumps({"message": {"content": "plain text"}}),
    ]
    (proj / "t.jsonl").write_text("\n".join(lines) + "\n", encoding="utf-8")
    r = digest.scan_transcripts(datetime.now() - timedelta(days=1))
    assert r["skills"]["recall"] == 2
    assert r["mcp"]["demo"] == 1
    assert r["agents"]["reviewer"] == 1
    assert r["brain_reads"] == 1
    assert r["tool_calls"] == 5


def test_digest_main_writes_file_and_prints_body(sandbox, capsys):
    digest = load("brain-digest")
    today = date.today()
    write_session(sandbox["brain"], "s.md", today, decisions=["D1", "D2"])
    assert digest.main(["--days", "7"]) == 0
    year, week, _ = today.isocalendar()
    out = sandbox["brain"] / "digests" / f"{year}-W{week:02d}.md"
    assert out.exists()
    body = out.read_text(encoding="utf-8")
    assert "type: digest" in body
    assert "Decisions recorded: 2" in body
    assert "Decisions recorded: 2" in capsys.readouterr().out
    assert not sandbox["touched"]


# ---------- bm-index ----------
def test_bm_index_counts_reads_sqlite_in_sandbox_home(sandbox):
    db_dir = sandbox["home"] / ".basic-memory"
    db_dir.mkdir()
    con = sqlite3.connect(db_dir / "memory.db")
    con.execute("create table entity (id integer)")
    con.execute("create table relation (id integer)")
    con.executemany("insert into entity values (?)", [(1,), (2,)])
    con.execute("insert into relation values (1)")
    con.commit()
    con.close()
    bm = load("bm-index")
    assert bm.counts() == (2, 1)


def test_bm_index_counts_missing_db(sandbox):
    bm = load("bm-index")
    assert bm.counts() == (-1, -1)
