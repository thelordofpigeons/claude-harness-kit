"""Shared helpers for the hygiene scanners: tree walking and path rules."""
from __future__ import annotations

from pathlib import Path

# Directories that are never part of the published tree. .git and .hygiene are the two
# the design names; the rest are tool caches that git ignores anyway.
SKIP_DIRS = {".git", ".hygiene", "node_modules", "__pycache__", ".pytest_cache"}


def default_root() -> Path:
    return Path(__file__).resolve().parents[2]


def iter_files(root: Path, subpaths: list[str] | None = None):
    """Yield (absolute Path, posix relative path) for every file under root, skipping SKIP_DIRS."""
    bases = [root / s for s in subpaths] if subpaths else [root]
    for base in bases:
        if base.is_file():
            yield base, base.relative_to(root).as_posix()
            continue
        if not base.is_dir():
            continue
        stack = [base]
        while stack:
            d = stack.pop()
            try:
                entries = sorted(d.iterdir())
            except OSError:
                continue
            for e in entries:
                if e.is_dir():
                    if e.name in SKIP_DIRS:
                        continue
                    stack.append(e)
                elif e.is_file():
                    yield e, e.relative_to(root).as_posix()


def is_binary(data: bytes) -> bool:
    return b"\x00" in data[:8192]
