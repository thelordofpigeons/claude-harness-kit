#!/usr/bin/env python3
"""dash_scan.py: text hygiene scanner (rules R7 and R14).

Rules (ids printed in the report):
  R7-dash      en dash or em dash character
  R7-entity    HTML entity form of those dashes
  R7-escape    backslash-u escape text for those dashes
  R7-emoji     emoji or dingbat (U+1F300-1FAFF, U+2600-27BF, U+FE0F), check marks included
  R7-mojibake  broken UTF-8 round trip sequences
  R7-bom       UTF-8 byte order mark
  R7-cr        carriage return anywhere (LF only)
  R7-utf8      file is not valid UTF-8
  R14-binary   NUL bytes (no binaries in the kit)
  R14-size     file larger than 60 KB
  R14-eof      missing final newline

Literal dash characters are never allowed. The entity and escape forms are the subject
matter of the design linter, so they are tolerated in scripts/design-lint.mjs and in
scripts/fixtures/. Patterns are built from code points so this file holds no dash itself.

Usage: python tools/hygiene/dash_scan.py [--root DIR]
Exit 0 clean, 1 findings.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import NamedTuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _common import default_root, is_binary, iter_files  # noqa: E402

MAX_BYTES = 60 * 1024

DASH_RE = re.compile("[" + chr(0x2013) + chr(0x2014) + "]")
ENTITY_RE = re.compile(r"(?i)&(?:m|n)dash;|&#(?:8211|8212);|&#x(?:2013|2014);")
ESCAPE_RE = re.compile(r"(?i)\\u\{?(?:2013|2014)\}?|\\x\{(?:2013|2014)\}")
EMOJI_RE = re.compile("[" + chr(0x1F300) + "-" + chr(0x1FAFF) + chr(0x2600) + "-" + chr(0x27BF) + chr(0xFE0F) + "]")
MOJIBAKE_RE = re.compile(chr(0xE2) + chr(0x20AC) + "|" + chr(0xC3) + chr(0xA2))

ENTITY_ESCAPE_EXEMPT_PREFIXES = ("scripts/design-lint.mjs", "scripts/fixtures/")


class Finding(NamedTuple):
    path: str
    line: int
    rule: str


def scan_file(rel: str, data: bytes) -> list[Finding]:
    out: list[Finding] = []
    if is_binary(data):
        return [Finding(rel, 0, "R14-binary")]
    if len(data) > MAX_BYTES:
        out.append(Finding(rel, 0, "R14-size"))
    if data.startswith(b"\xef\xbb\xbf"):
        out.append(Finding(rel, 1, "R7-bom"))
    if b"\r" in data:
        line_no = data[: data.index(b"\r")].count(b"\n") + 1
        out.append(Finding(rel, line_no, "R7-cr"))
    if data and not data.endswith(b"\n"):
        out.append(Finding(rel, data.count(b"\n") + 1, "R14-eof"))
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        out.append(Finding(rel, 0, "R7-utf8"))
        return out
    exempt = rel.startswith(ENTITY_ESCAPE_EXEMPT_PREFIXES)
    for i, line in enumerate(text.splitlines(), 1):
        if DASH_RE.search(line):
            out.append(Finding(rel, i, "R7-dash"))
        if not exempt and ENTITY_RE.search(line):
            out.append(Finding(rel, i, "R7-entity"))
        if not exempt and ESCAPE_RE.search(line):
            out.append(Finding(rel, i, "R7-escape"))
        if EMOJI_RE.search(line):
            out.append(Finding(rel, i, "R7-emoji"))
        if MOJIBAKE_RE.search(line):
            out.append(Finding(rel, i, "R7-mojibake"))
    return out


def scan_tree(root: Path, subpaths: list[str] | None = None) -> list[Finding]:
    findings: list[Finding] = []
    for path, rel in iter_files(root, subpaths):
        try:
            data = path.read_bytes()
        except OSError:
            continue
        findings += scan_file(rel, data)
    return findings


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Scan the kit for dashes, emoji, BOM, CR and size problems.")
    ap.add_argument("--root", type=Path, default=default_root())
    args = ap.parse_args(argv)
    root = args.root.resolve()
    if not root.is_dir():
        print(f"dash_scan: root not found: {root}", file=sys.stderr)
        return 2
    findings = scan_tree(root)
    for f in findings:
        loc = f.path if f.line == 0 else f"{f.path}:{f.line}"
        print(f"{loc}: {f.rule}")
    if findings:
        print(f"dash_scan: {len(findings)} finding(s) in {len({f.path for f in findings})} file(s)")
        return 1
    print("dash_scan: clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
