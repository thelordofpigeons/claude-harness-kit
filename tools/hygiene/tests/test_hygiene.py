"""Tests for the hygiene scanners.

Every planted leak is assembled from fragments at runtime and written into a pytest tmp
dir, so the committed tree holds no leak-shaped strings and the scanners can run over it
without any path exclusion.

Run: python -m pytest tools/hygiene/tests -q
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
HYGIENE = HERE.parent
REPO = HYGIENE.parent.parent
sys.path.insert(0, str(HYGIENE))

import dash_scan  # noqa: E402
import leak_scan  # noqa: E402

EM = chr(0x2014)
EN = chr(0x2013)
GIT = shutil.which("git")


def rules(findings) -> set[str]:
    return {f.rule for f in findings}


def make_tree(tmp_path: Path, files: dict[str, str]) -> Path:
    for rel, text in files.items():
        p = tmp_path / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(text.encode("utf-8"))
    return tmp_path


# ---------------------------------------------------------------- leak_scan: pattern rules
PLANTED = [
    ("R2", "x.md", "see " + "C:" + "\\Users\\" + "someone" + "\\notes\n"),
    ("R2", "x.md", "open /" + "home" + "/someone/" + "project\n"),
    ("R2", "x.md", "cache in " + "App" + "Data" + "\\Local\n"),
    ("R2", "x.md", "repos at " + "Documents" + "/Work/" + "Dev" + "\n"),
    ("R3", "x.md", "mail " + "dev" + "@" + "acme-corp" + ".net please\n"),
    ("R4", "x.md", "task " + "86" + "can" + "09h9" + "\n"),
    ("R4", "x.md", "list " + "9015" + "10389898" + "\n"),
    ("R4", "x.md", "id " + "12345" + "6789" + "012" + "\n"),
    ("R4", "x.md", "app " + "app" + "_" + "12345678-1234-1234-1234-" + "123456789abc" + "\n"),
    ("R4", "x.md", "org " + "org" + "_" + "abc12345xyz" + "\n"),
    ("R4", "x.md", "trigger " + "trig" + "_" + "01AbCdEfGh" + "\n"),
    ("R4", "x.md", "uuid " + "12345678-" + "abcd-abcd-abcd-" + "123456789abc" + "\n"),
    ("R5", "x.md", "node " + "10." + "1.2.3" + "\n"),
    ("R5", "x.md", "node " + "100." + "100.1.1" + "\n"),
    ("R5", "x.md", "node " + "192." + "168.0.7" + "\n"),
    ("R5", "x.md", "host " + "box" + ".ts" + ".net" + "\n"),
    ("R5", "x.md", "app " + "demo" + ".clever" + "apps" + ".io" + "\n"),
    ("R5", "x.md", "see " + "https" + "://" + "wiki.acme-corp.net/page" + "\n"),
    ("R5", "x.sh", "git clone " + "git" + "@" + "git.acme-corp.net" + ":team/repo.git\n"),
    ("R5", "x.sh", "git remote add o " + "ssh" + "://" + "git@" + "git.acme-corp.net/r.git\n"),
    ("R6", "x.md", "key " + "sk" + "-" + "A" * 24 + "\n"),
    ("R6", "x.md", "key " + "gh" + "p_" + "A" * 36 + "\n"),
    ("R6", "x.md", "key " + "github" + "_pat_" + "A" * 24 + "\n"),
    ("R6", "x.md", "key " + "xox" + "b-" + "12345" + "67890" + "ab" + "\n"),
    ("R6", "x.md", "key " + "AKIA" + "ABCDEFGHIJKLMNOP" + "\n"),
    ("R6", "x.md", "jwt " + "eyJ" + "a" * 12 + "." + "b" * 12 + "\n"),
    ("R6", "x.md", "-----" + "BEGIN " + "RSA PRIVATE" + " KEY" + "-----\n"),
    ("R6", "x.sh", "api" + "_key" + ' = "' + "x" * 16 + '"\n'),
    ("R6", "x.sh", "curl -H 'Authorization: " + "Bearer " + "abcdef123456'\n"),
    ("R6b", "x.sh", "cat ~/.claude/." + "cred" + "entials.json\n"),
    ("R6b", "x.mjs", "const t = j." + "access" + "Token;\n"),
    ("R6b", "x.py", "import " + "key" + "tar\n"),
    ("R6b", "x.ps1", "Get-Content 'Login" + " Data'\n"),
    ("R9", "x.md", "written " + "2026" + "-10-05" + "\n"),
    ("R10", "x.md", "extension " + "abcdefghijklmnop" * 2 + "\n"),
    ("R6f", "usage-cache" + ".json", "{}\n"),
    ("R6f", ".cred" + "entials.json", "{}\n"),
    ("R6f", "settings." + "local" + ".json", "{}\n"),
    ("R6f", "current-task", "x\n"),
    ("R6f", "old.sh" + ".bak", "x\n"),
    ("R6f", "debug" + ".log", "x\n"),
]


@pytest.mark.parametrize("rule,fname,text", PLANTED, ids=[f"{r}-{i}" for i, (r, _, _) in enumerate(PLANTED)])
def test_planted_leak_is_flagged(tmp_path, rule, fname, text):
    make_tree(tmp_path, {fname: text})
    assert rule in rules(leak_scan.scan_tree(tmp_path))


CLEAN = [
    ("x.md", "Use $HOME/.claude and ~/brain, or ${BRAIN_DIR:-$HOME/brain}.\n"),
    ("x.md", "Contact user@example.com or noreply@anthropic.com. Clone git@github.com:owner/repo.git\n"),
    ("x.md", "Docs: https://code.claude.com/docs and http://localhost:3000/a\n"),
    ("x.md", "Fake dates are fine: 2025-01-15 and 2025-01-01. Numbers: 86400000 and 3600000.\n"),
    ("x.md", "Placeholders: <APP_ID> <ORG> <WORKSPACE_ID> and C:\\Users\\<you>\\x\n"),
    ("x.sh", "export TOKEN=\"$MY_TOKEN\"\ncurl -H \"Authorization: Bearer $MY_TOKEN\" localhost\n"),
    ("x.md", "Private ranges look like 10.x.x.x in prose, and 8.8.8.8 is public.\n"),
    ("x.md", "tools: typescript@5.3.2 and prettier@3.0.0\n"),
    ("x.md", "git push git+ssh://git@<push-host>/<APP_ID>.git HEAD:master\n"),
    ("tests/t.md", "synthetic " + "2031" + "-02-03 inside a tests folder\n"),
]


@pytest.mark.parametrize("fname,text", CLEAN, ids=[str(i) for i in range(len(CLEAN))])
def test_clean_text_passes(tmp_path, fname, text):
    make_tree(tmp_path, {fname: text})
    assert leak_scan.scan_tree(tmp_path) == []


def test_report_has_location_and_rule_only(tmp_path):
    make_tree(tmp_path, {"a/b.md": "ok\n" + "key " + "sk" + "-" + "A" * 24 + "\n"})
    out = subprocess.run([sys.executable, str(HYGIENE / "leak_scan.py"), "--root", str(tmp_path)],
                         capture_output=True, text=True)
    assert out.returncode == 1
    assert "a/b.md:2: R6" in out.stdout
    assert "A" * 24 not in out.stdout


# ---------------------------------------------------------------- denylist
TERM = "zork" + "blat"


def denylist_tree(tmp_path: Path, files: dict[str, str], lines: list[str], ignore: bool = True) -> Path:
    make_tree(tmp_path, files)
    (tmp_path / ".hygiene").mkdir()
    (tmp_path / ".hygiene" / "denylist.txt").write_text("# comment\n" + "\n".join(lines) + "\n", encoding="utf-8")
    if ignore:
        (tmp_path / ".gitignore").write_text(".hygiene/\n", encoding="utf-8")
    return tmp_path


def run_cli(root: Path, *extra: str):
    # Hermetic: no denylist from the environment or from the real home directory.
    env = {k: v for k, v in os.environ.items() if k != "KIT_DENYLIST"}
    fake_home = str(root / "_nohome")
    env["HOME"] = fake_home
    env["USERPROFILE"] = fake_home
    return subprocess.run([sys.executable, str(HYGIENE / "leak_scan.py"), "--root", str(root), *extra],
                          capture_output=True, text=True, env=env)


@pytest.mark.parametrize("text", [
    f"the {TERM} project\n",
    f"the {TERM.upper()} project\n",
    f"the {TERM.capitalize()}Service class\n",
    f"my{TERM.capitalize()} variable\n",
    f"path {TERM}-core/x\n",
])
def test_denylist_term_variants_are_flagged(tmp_path, text):
    root = denylist_tree(tmp_path, {"a.md": text}, [TERM])
    dl = leak_scan.Denylist.load(root / ".hygiene" / "denylist.txt")
    assert "R1" in rules(leak_scan.scan_tree(root, dl))


def test_denylist_short_terms_are_whole_word_only(tmp_path):
    short = "bl" + "orp"  # under 6 characters: no squashed substring match
    root = denylist_tree(tmp_path, {"a.md": f"{short}ology is not the term\n", "b.md": f"{short} is\n"}, [short])
    dl = leak_scan.Denylist.load(root / ".hygiene" / "denylist.txt")
    hit = {f.path for f in leak_scan.scan_tree(root, dl) if f.rule == "R1"}
    assert hit == {"b.md"}


def test_denylist_squashed_form_catches_separator_variants(tmp_path):
    term = "blue " + "falcon" + " works"
    root = denylist_tree(tmp_path, {"a.md": "repo blue_falcon-works here\n", "b.md": "BlueFalconWorks\n"}, [term])
    dl = leak_scan.Denylist.load(root / ".hygiene" / "denylist.txt")
    hit = {f.path for f in leak_scan.scan_tree(root, dl) if f.rule == "R1"}
    assert hit == {"a.md", "b.md"}


def test_denylist_matched_term_is_never_printed(tmp_path):
    root = denylist_tree(tmp_path, {"a.md": f"the {TERM} project\n"}, [TERM])
    out = run_cli(root)
    assert out.returncode == 1
    assert "a.md:1: R1" in out.stdout
    assert TERM not in out.stdout + out.stderr


def test_warn_terms_need_template_marker(tmp_path):
    root = denylist_tree(
        tmp_path,
        {
            "plain.md": f"uses {TERM}\n",
            "tmpl.md": f"TEMPLATE: params\nuses {TERM}\n",
            "late.md": "\n" * 20 + f"TEMPLATE: late\nuses {TERM}\n",
            "docs/07-what-was-removed.md": f"mentions {TERM}\n",
        },
        ["warn:" + TERM],
    )
    dl = leak_scan.Denylist.load(root / ".hygiene" / "denylist.txt")
    flagged = {f.path for f in leak_scan.scan_tree(root, dl) if f.rule == "R1w"}
    assert flagged == {"plain.md", "late.md"}


def test_denylist_missing_strict_fails_nonstrict_passes(tmp_path):
    make_tree(tmp_path, {"a.md": "clean\n"})
    assert run_cli(tmp_path, "--strict").returncode == 1
    assert "R1-missing" in run_cli(tmp_path, "--strict").stdout
    assert run_cli(tmp_path).returncode == 0


def test_denylist_must_be_git_ignored(tmp_path):
    root = denylist_tree(tmp_path, {"a.md": "clean\n"}, [TERM], ignore=False)
    out = run_cli(root)
    assert out.returncode == 1 and "R1-notignored" in out.stdout


def test_denylist_ignored_passes(tmp_path):
    root = denylist_tree(tmp_path, {"a.md": "clean\n"}, [TERM], ignore=True)
    assert run_cli(root, "--strict").returncode == 0


@pytest.mark.skipif(GIT is None, reason="git not available")
def test_denylist_ignore_check_uses_git_when_repo(tmp_path):
    root = denylist_tree(tmp_path, {"a.md": "clean\n"}, [TERM], ignore=True)
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    assert run_cli(root, "--strict").returncode == 0
    (root / ".gitignore").write_text("", encoding="utf-8")
    assert "R1-notignored" in run_cli(root, "--strict").stdout


def test_hygiene_dir_and_git_dir_are_not_scanned(tmp_path):
    leak = "key " + "sk" + "-" + "A" * 24 + "\n"
    make_tree(tmp_path, {".hygiene/notes.md": leak, ".git/x.md": leak, "ok.md": "fine\n"})
    assert leak_scan.scan_tree(tmp_path) == []


# ---------------------------------------------------------------- history
def git(root: Path, *args: str):
    return subprocess.run(
        ["git", "-C", str(root), "-c", "user.name=tester", "-c", "user.email=tester@example.com", *args],
        capture_output=True, text=True, check=True)


@pytest.mark.skipif(GIT is None, reason="git not available")
def test_history_scan_finds_leak_removed_in_later_commit(tmp_path):
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)
    leak = "key " + "sk" + "-" + "A" * 24 + "\n"
    (tmp_path / "a.md").write_text(leak, encoding="utf-8")
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "first")
    (tmp_path / "a.md").write_text("clean now\n", encoding="utf-8")
    git(tmp_path, "commit", "-q", "-am", "second")
    assert leak_scan.scan_tree(tmp_path) == []
    found = leak_scan.scan_history(tmp_path)
    assert "R6" in rules(found)
    assert run_cli(tmp_path, "--history").returncode == 1
    assert run_cli(tmp_path).returncode == 0


@pytest.mark.skipif(GIT is None, reason="git not available")
def test_history_scan_clean_repo_and_empty_repo(tmp_path):
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)
    assert run_cli(tmp_path, "--history").returncode == 0
    (tmp_path / "a.md").write_text("fine\n", encoding="utf-8")
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "ok\n\nCo-Authored-By: Someone <noreply@anthropic.com>")
    assert run_cli(tmp_path, "--history").returncode == 0


@pytest.mark.skipif(GIT is None, reason="git not available")
def test_history_scan_flags_private_author_email_and_forbidden_file(tmp_path):
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)
    (tmp_path / "current-task").write_text("x\n", encoding="utf-8")
    git(tmp_path, "add", "-A")
    subprocess.run(
        ["git", "-C", str(tmp_path), "-c", "user.name=t", "-c", "user.email=" + "me@" + "acme-corp.net",
         "commit", "-q", "-m", "c"], check=True, capture_output=True)
    found = rules(leak_scan.scan_history(tmp_path))
    assert {"R3", "R6f"} <= found


@pytest.mark.skipif(GIT is None, reason="git not available")
def test_history_scan_denylist_hit_in_added_line(tmp_path):
    root = denylist_tree(tmp_path, {"a.md": f"about {TERM}\n"}, [TERM])
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "c")
    dl = leak_scan.Denylist.load(root / ".hygiene" / "denylist.txt")
    assert "R1" in rules(leak_scan.scan_history(root, dl))


# ---------------------------------------------------------------- dash_scan
DASH_PLANTED = [
    ("R7-dash", "x.md", "a " + EM + " b\n"),
    ("R7-dash", "x.md", "a " + EN + " b\n"),
    ("R7-entity", "x.md", "a &" + "mdash;" + " b\n"),
    ("R7-entity", "x.md", "a &" + "ndash;" + " b\n"),
    ("R7-entity", "x.md", "a &#" + "8212;" + " b\n"),
    ("R7-entity", "x.md", "a &#" + "8211;" + " b\n"),
    ("R7-escape", "x.md", "a \\" + "u2014" + " b\n"),
    ("R7-escape", "x.md", "a \\" + "u2013" + " b\n"),
    ("R7-escape", "x.md", "a \\" + "x{2014}" + " b\n"),
    ("R7-emoji", "x.md", "done " + chr(0x2705) + "\n"),
    ("R7-emoji", "x.md", "done " + chr(0x2714) + "\n"),
    ("R7-emoji", "x.md", "party " + chr(0x1F389) + "\n"),
    ("R7-emoji", "x.md", "star" + chr(0xFE0F) + "\n"),
    ("R7-mojibake", "x.md", "a " + chr(0xE2) + chr(0x20AC) + chr(0x201D) + " b\n"),
]


@pytest.mark.parametrize("rule,fname,text", DASH_PLANTED, ids=[f"{r}-{i}" for i, (r, _, _) in enumerate(DASH_PLANTED)])
def test_dash_planted_is_flagged(tmp_path, rule, fname, text):
    make_tree(tmp_path, {fname: text})
    assert rule in rules(dash_scan.scan_tree(tmp_path))


def test_dash_bom_cr_eof_size_binary_utf8(tmp_path):
    (tmp_path / "bom.md").write_bytes(b"\xef\xbb\xbfhello\n")
    (tmp_path / "cr.md").write_bytes(b"a\r\nb\r\n")
    (tmp_path / "eof.md").write_bytes(b"no newline")
    (tmp_path / "big.md").write_bytes(b"x" * 70000 + b"\n")
    (tmp_path / "bin.dat").write_bytes(b"ab\x00cd\n")
    (tmp_path / "bad.md").write_bytes(b"caf\xe9\n")
    got = {(f.path, f.rule) for f in dash_scan.scan_tree(tmp_path)}
    assert ("bom.md", "R7-bom") in got
    assert ("cr.md", "R7-cr") in got
    assert ("eof.md", "R14-eof") in got
    assert ("big.md", "R14-size") in got
    assert ("bin.dat", "R14-binary") in got
    assert ("bad.md", "R7-utf8") in got


def test_dash_clean_text_passes(tmp_path):
    ok = "Arrows -> and " + chr(0x2192) + " are allowed, box " + chr(0x2500) + ", dot " + chr(0xB7) + ", caf" + chr(0xE9) + "\n"
    make_tree(tmp_path, {"x.md": ok, "empty.md": ""})
    assert dash_scan.scan_tree(tmp_path) == []


def test_dash_entity_and_escape_tolerated_only_in_linter_paths(tmp_path):
    text = "const re = /&" + "mdash;|\\" + "u2014/;\n"
    make_tree(tmp_path, {"scripts/design-lint.mjs": text, "scripts/fixtures/bad.tsx": text, "other.mjs": text})
    flagged = {f.path for f in dash_scan.scan_tree(tmp_path)}
    assert flagged == {"other.mjs"}


def test_literal_dash_never_tolerated_even_in_linter_paths(tmp_path):
    make_tree(tmp_path, {"scripts/design-lint.mjs": "x " + EM + " y\n"})
    assert "R7-dash" in rules(dash_scan.scan_tree(tmp_path))


def test_dash_cli_exit_codes(tmp_path):
    make_tree(tmp_path, {"x.md": "clean\n"})
    ok = subprocess.run([sys.executable, str(HYGIENE / "dash_scan.py"), "--root", str(tmp_path)], capture_output=True, text=True)
    assert ok.returncode == 0
    make_tree(tmp_path, {"y.md": "bad " + EM + "\n"})
    bad = subprocess.run([sys.executable, str(HYGIENE / "dash_scan.py"), "--root", str(tmp_path)], capture_output=True, text=True)
    assert bad.returncode == 1 and "y.md:1: R7-dash" in bad.stdout


# ---------------------------------------------------------------- the scanners and tests are clean themselves
def test_own_sources_are_clean():
    subs = ["tools", "memory"]
    assert leak_scan.scan_tree(REPO, None, subs) == []
    assert dash_scan.scan_tree(REPO, subs) == []
