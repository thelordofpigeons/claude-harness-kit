#!/usr/bin/env python3
"""leak_scan.py: scan the working tree (and optionally git history) for private material.

Rules (ids are what the report prints; matched text is never printed):
  R1   denylist term (whole word, camel/kebab variants, squashed form for long terms)
  R1w  denylist term marked `warn:` (public tool names) outside a file whose first 15
       lines carry the marker line TEMPLATE: (docs/07-what-was-removed.md is exempt)
  R1-missing / R1-notignored   denylist absent (strict) or not git-ignored
  R2   absolute user paths
  R3   email addresses (small allowlist)
  R4   tracker and platform identifiers, UUIDs
  R5   private network addresses, internal hostnames, unlisted URL hosts and git remotes
  R6   secret-shaped strings
  R6b  code that reads stored logins, token stores or browser profiles
  R6f  file names that must never ship
  R9   dated strings (only two synthetic dates are allowed, and anything under tests/)
  R10  Chrome extension id shaped strings

The denylist is a private file kept OUTSIDE the repository folder so that copying or zipping
the folder cannot ship it. Lookup order: --denylist FILE, $KIT_DENYLIST,
~/.config/claude-harness-kit/denylist.txt, then <root>/.hygiene/denylist.txt (git-ignored,
used by the tests). One term per line, '#' starts a comment, 'warn:' prefix marks a public
tool name.

Usage:
  python tools/hygiene/leak_scan.py [--root DIR] [--denylist FILE] [--history] [--strict]
Exit 0 clean, 1 findings, 2 usage error.
"""
from __future__ import annotations

import argparse
import fnmatch
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import NamedTuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _common import default_root, is_binary, iter_files  # noqa: E402


class Finding(NamedTuple):
    path: str
    line: int
    rule: str


CODE_EXT = {".sh", ".bash", ".mjs", ".js", ".cjs", ".ts", ".tsx", ".py", ".ps1"}

# ---- R2 paths ----
PATH_RES = [
    re.compile(r"(?i)[A-Z]:[\\/]+Users[\\/]+(?![<$%{])[^\\/\s]+"),
    re.compile(r"(?i)/(?:Users|home)/(?![<$%{])[a-z0-9._-]+/"),
    re.compile(r"(?i)AppData[\\/]"),
    re.compile(r"(?i)Documents[\\/]+[A-Za-z0-9_-]+[\\/]+(?:Dev|kb|Projects)\b"),
]

# ---- R3 email ----
EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}")
EMAIL_ALLOW = re.compile(
    r"(?i)^(?:noreply@anthropic\.com|user@example\.com|[^@]+@example\.(?:com|org)|[^@]+@users\.noreply\.github\.com|git@github\.com)$"
)

# ---- R4 identifiers ----
ID_RES = [
    re.compile(r"\b86(?=[a-z0-9]*[a-z])[a-z0-9]{6,9}\b"),
    re.compile(r"\b9015\d{8,10}\b"),
    re.compile(r"app_[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}"),
    re.compile(r"org_(?=[0-9a-zA-Z]*\d)[0-9a-zA-Z]{8,}"),
    re.compile(r"trig_(?=[A-Za-z0-9]*\d)[A-Za-z0-9]{8,}"),
    re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"),
]
LONG_NUM_RE = re.compile(r"\b\d{9,13}\b")
LONG_NUM_ALLOW = {"1000000000", "2147483647", "4294967295", "1000000000000"}

# ---- R5 network ----
IPV4_RE = re.compile(
    r"\b(?:10\.\d+\.\d+\.\d+|192\.168\.\d+\.\d+|172\.(?:1[6-9]|2\d|3[01])\.\d+\.\d+"
    r"|100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d+\.\d+)\b"
)
HOST_RE = re.compile(r"(?i)\b[a-z0-9-]+\.(?:ts\.net|cleverapps\.io|internal|local|lan)\b(?!\.[a-z])")
URL_RE = re.compile(r"(?i)\bhttps?://([^/\s\"'<>)\]\\]+)")
GITREMOTE_RE = re.compile(r"(?i)(?:\bgit@([a-z0-9.-]+):|\bssh://(?:[^@/\s]+@)?([a-z0-9.-]+)(?![\w.@-]))")
HOST_ALLOW = (
    "docs.anthropic.com", "code.claude.com", "developer.chrome.com", "chromedevtools.github.io",
    "www.w3.org", "developer.mozilla.org",
    # additional public hosts that carry no private information
    "anthropic.com", "claude.com", "github.com", "localhost", "127.0.0.1", "0.0.0.0",
    "example.com", "example.org", "example.net", "json.schemastore.org", "json-schema.org",
    "prettier.io", "eslint.org", "www.typescriptlang.org", "nodejs.org", "pytest.org",
    "orm.drizzle.team", "www.npmjs.com", "npmjs.com", "img.shields.io",
)


def host_allowed(host: str) -> bool:
    h = host.lower().split("@")[-1]
    h = re.sub(r":\d+$", "", h)
    if not h or h[0] in "<${*%" or "$" in h or "{" in h:
        return True
    return any(h == a or h.endswith("." + a) for a in HOST_ALLOW)


# ---- R6 secrets ----
SECRET_RES = [
    re.compile(r"sk-[A-Za-z0-9_-]{20,}"),
    re.compile(r"gh[pousr]_[A-Za-z0-9]{30,}"),
    re.compile(r"github_pat_[A-Za-z0-9_]{20,}"),
    re.compile(r"xox[baprs]-[A-Za-z0-9-]{10,}"),
    re.compile(r"AKIA[0-9A-Z]{16}"),
    re.compile(r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"),
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    re.compile(r"""(?i)(?:api[_-]?key|secret|token|passw(?:or)?d|bearer)\s*[:=]\s*["'][^"'\s<${]{12,}["']"""),
    re.compile(r"Authorization:\s*Bearer\s+(?!\$|<|\{)"),
]
# R6b is built from fragments so this file does not trip its own rule.
CRED_RE = re.compile(
    "(?i)" + "|".join(["cred" "entials", "access" "token", "o" "auth", "key" "tar", "login" " data", "key" "chain"])
)

# ---- R6f file names ----
FORBIDDEN_NAMES = [
    "usage-cache*", ".cred" "entials*", "settings.local.json", "current-task*", "click" "up-config*",
    "design-log*", "design-taste*", "*.bak", "*.sync-conflict-*", "*.pyc", "*.log", ".env*",
]

# ---- R9 dates, R10 extension ids ----
DATE_RE = re.compile(r"\b20\d\d-\d\d-\d\d\b")
DATE_ALLOW = {"2025-01-15", "2025-01-01"}
EXT_ID_RE = re.compile(r"\b[a-p]{32}\b")

TEMPLATE_EXEMPT_PATHS = {"docs/07-what-was-removed.md"}


# ---------------- denylist ----------------
class Denylist:
    def __init__(self, terms: list[tuple[str, bool]]):
        self.entries = []
        for term, warn in terms:
            words = [w for w in re.split(r"[\s_-]+", term.strip()) if w]
            if not words:
                continue
            body = r"[\s_-]*".join(re.escape(w) for w in words)
            patterns = [re.compile(r"(?<![A-Za-z0-9])(?i:" + body + r")(?![a-z0-9])")]
            if len(words) == 1:
                patterns.append(re.compile(r"(?<=[a-z0-9])" + re.escape(words[0].capitalize()) + r"(?![a-z0-9])"))
            squashed = "".join(w.lower() for w in words)
            self.entries.append((patterns, squashed if len(squashed) >= 6 else None, warn))

    @classmethod
    def load(cls, path: Path) -> "Denylist":
        terms = []
        for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
            s = raw.strip()
            if not s or s.startswith("#"):
                continue
            warn = False
            if s.lower().startswith("warn:"):
                warn, s = True, s[5:].strip()
            terms.append((s, warn))
        return cls(terms)

    def hits(self, line: str) -> set[bool]:
        """Return the set of warn-flags for entries that match (False = hard, True = warn)."""
        out: set[bool] = set()
        squashed_line = None
        for patterns, squashed, warn in self.entries:
            if any(p.search(line) for p in patterns):
                out.add(warn)
                continue
            if squashed:
                if squashed_line is None:
                    squashed_line = re.sub(r"[\s_-]+", "", line.lower())
                if squashed in squashed_line:
                    out.add(warn)
        return out


def has_template_marker(lines: list[str]) -> bool:
    return any("TEMPLATE:" in ln for ln in lines[:15])


# ---------------- line rules ----------------
def line_rules(rel: str, line: str, in_tests: bool) -> set[str]:
    rules: set[str] = set()
    ext = Path(rel).suffix.lower()
    if any(p.search(line) for p in PATH_RES):
        rules.add("R2")
    for m in EMAIL_RE.finditer(line):
        if not EMAIL_ALLOW.match(m.group(0)):
            rules.add("R3")
    if any(p.search(line) for p in ID_RES):
        rules.add("R4")
    for m in LONG_NUM_RE.finditer(line):
        if m.group(0) not in LONG_NUM_ALLOW:
            rules.add("R4")
    if IPV4_RE.search(line) or HOST_RE.search(line):
        rules.add("R5")
    for m in URL_RE.finditer(line):
        if not host_allowed(m.group(1)):
            rules.add("R5")
    for m in GITREMOTE_RE.finditer(line):
        if not host_allowed(m.group(1) or m.group(2) or ""):
            rules.add("R5")
    if any(p.search(line) for p in SECRET_RES):
        rules.add("R6")
    if ext in CODE_EXT and CRED_RE.search(line):
        rules.add("R6b")
    if not in_tests:
        for m in DATE_RE.finditer(line):
            if m.group(0) not in DATE_ALLOW:
                rules.add("R9")
    if EXT_ID_RE.search(line):
        rules.add("R10")
    return rules


def name_rules(rel: str) -> list[str]:
    base = rel.rsplit("/", 1)[-1]
    return ["R6f"] if any(fnmatch.fnmatch(base, pat) for pat in FORBIDDEN_NAMES) else []


# ---------------- denylist git-ignore check ----------------
def denylist_ignored(root: Path, denylist: Path) -> bool:
    try:
        rel = denylist.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return True  # outside the tree, cannot be committed
    if (root / ".git").exists():
        r = subprocess.run(["git", "-C", str(root), "check-ignore", "-q", "--", rel], capture_output=True)
        return r.returncode == 0
    gi = root / ".gitignore"
    if not gi.is_file():
        return False
    entries = {ln.strip().lstrip("/") for ln in gi.read_text(encoding="utf-8", errors="replace").splitlines()}
    parent = rel.rsplit("/", 1)[0] + "/" if "/" in rel else ""
    return bool(entries & {rel, parent, parent.rstrip("/"), parent + "*"})


# ---------------- tree scan ----------------
def scan_tree(root: Path, denylist: Denylist | None = None, subpaths: list[str] | None = None) -> list[Finding]:
    findings: list[Finding] = []
    for path, rel in iter_files(root, subpaths):
        for rule in name_rules(rel):
            findings.append(Finding(rel, 0, rule))
        try:
            data = path.read_bytes()
        except OSError:
            continue
        if is_binary(data):
            continue
        lines = data.decode("utf-8", errors="replace").splitlines()
        in_tests = "tests" in rel.split("/")[:-1]
        template_ok = has_template_marker(lines) or rel in TEMPLATE_EXEMPT_PATHS
        for i, line in enumerate(lines, 1):
            rules = line_rules(rel, line, in_tests)
            if denylist is not None:
                flags = denylist.hits(line)
                if False in flags:
                    rules.add("R1")
                if True in flags and not template_ok:
                    rules.add("R1w")
            for r in sorted(rules):
                findings.append(Finding(rel, i, r))
    return findings


# ---------------- history scan ----------------
def scan_history(root: Path, denylist: Denylist | None = None) -> list[Finding]:
    fmt = "commit %H%n%an <%ae>%n%cn <%ce>%n%B%n--end-message--"
    r = subprocess.run(
        ["git", "-C", str(root), "-c", "core.quotepath=false", "log", "--all", "-p", "--no-color", "--format=" + fmt],
        capture_output=True,
    )
    if r.returncode != 0:
        return []  # no commits yet
    text = r.stdout.decode("utf-8", errors="replace").splitlines()
    findings: list[Finding] = []
    sha = "0000000"
    path = "<message>"
    in_message = False
    seen_names: set[tuple[str, str]] = set()
    marker_cache: dict[str, bool] = {}
    for n, raw in enumerate(text, 1):
        if raw.startswith("commit ") and re.fullmatch(r"commit [0-9a-f]{40}", raw):
            sha, path, in_message = raw[7:14], "<message>", True
            continue
        if in_message:
            if raw == "--end-message--":
                in_message = False
                path = "<diff>"
                continue
            line, rel = raw, "<message>"
        elif raw.startswith("+++ "):
            tgt = raw[4:]
            path = tgt[2:] if tgt.startswith("b/") else tgt
            if path != "/dev/null" and (sha, path) not in seen_names:
                seen_names.add((sha, path))
                for rule in name_rules(path):
                    findings.append(Finding(f"history:{sha}:{path}", n, rule))
            continue
        elif raw.startswith("+") and not raw.startswith("+++"):
            line, rel = raw[1:], path
        else:
            continue
        in_tests = "tests" in rel.split("/")[:-1]
        rules = line_rules(rel, line, in_tests)
        if denylist is not None:
            flags = denylist.hits(line)
            if False in flags:
                rules.add("R1")
            if True in flags:
                if rel not in marker_cache:
                    fp = root / rel
                    try:
                        marker_cache[rel] = has_template_marker(fp.read_text(encoding="utf-8", errors="replace").splitlines())
                    except OSError:
                        marker_cache[rel] = False
                if not (marker_cache[rel] or rel in TEMPLATE_EXEMPT_PATHS):
                    rules.add("R1w")
        for rule in sorted(rules):
            findings.append(Finding(f"history:{sha}:{rel}", n, rule))
    return findings


# ---------------- CLI ----------------
def resolve_denylist(explicit: Path | None, root: Path) -> Path:
    if explicit:
        return explicit
    env = os.environ.get("KIT_DENYLIST")
    if env:
        return Path(env)
    home_default = Path.home() / ".config" / "claude-harness-kit" / "denylist.txt"
    if home_default.is_file():
        return home_default
    return root / ".hygiene" / "denylist.txt"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Scan the kit for private material.")
    ap.add_argument("--root", type=Path, default=default_root())
    ap.add_argument("--denylist", type=Path, default=None, help="default: $KIT_DENYLIST, ~/.config/claude-harness-kit/denylist.txt, <root>/.hygiene/denylist.txt")
    ap.add_argument("--history", action="store_true", help="also scan added lines in git history")
    ap.add_argument("--strict", action="store_true", help="fail when the denylist is missing")
    args = ap.parse_args(argv)

    root = args.root.resolve()
    if not root.is_dir():
        print(f"leak_scan: root not found: {root}", file=sys.stderr)
        return 2
    dl_path = resolve_denylist(args.denylist, root)
    findings: list[Finding] = []
    denylist = None
    if dl_path.is_file():
        denylist = Denylist.load(dl_path)
        if not denylist_ignored(root, dl_path):
            findings.append(Finding("denylist", 0, "R1-notignored"))
    elif args.strict:
        findings.append(Finding("denylist", 0, "R1-missing"))
    else:
        print("leak_scan: denylist missing, rule R1 skipped (use --strict to fail)", file=sys.stderr)

    findings += scan_tree(root, denylist)
    if args.history:
        findings += scan_history(root, denylist)

    for f in findings:
        loc = f.path if f.line == 0 else f"{f.path}:{f.line}"
        print(f"{loc}: {f.rule}")
    if findings:
        print(f"leak_scan: {len(findings)} finding(s) in {len({f.path for f in findings})} file(s)")
        return 1
    print("leak_scan: clean" + (" (tree and history)" if args.history else " (tree)"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
