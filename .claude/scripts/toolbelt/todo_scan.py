#!/usr/bin/env python3
"""Scan for TODO/FIXME/HACK/XXX markers, printing path:line refs.

Usage: todo_scan.py <dir> [--markers TODO,FIXME,HACK,XXX]
"""
import argparse
import re
import sys
from pathlib import Path

SKIP_DIRS = {".git", "node_modules", "__pycache__", ".venv", "venv",
             "dist", "build", ".claude"}
TEXT_SUFFIXES = {".py", ".js", ".ts", ".tsx", ".jsx", ".go", ".rs", ".java",
                 ".rb", ".php", ".c", ".h", ".cpp", ".cs", ".sh", ".ps1",
                 ".md", ".yaml", ".yml", ".toml", ".cfg", ".ini", ".html",
                 ".css", ".scss", ".sql", ".txt"}


def scan(root, markers):
    pattern = re.compile(r"\b(" + "|".join(re.escape(m) for m in markers) + r")\b")
    hits = []
    for path in sorted(Path(root).rglob("*")):
        if not path.is_file() or path.suffix.lower() not in TEXT_SUFFIXES:
            continue
        if any(part in SKIP_DIRS for part in path.parts):
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for lineno, line in enumerate(text.splitlines(), 1):
            match = pattern.search(line)
            if match:
                hits.append((str(path), lineno, match.group(1), line.strip()[:120]))
    return hits


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("root")
    parser.add_argument("--markers", default="TODO,FIXME,HACK,XXX")
    args = parser.parse_args(argv)

    markers = [m.strip() for m in args.markers.split(",") if m.strip()]
    hits = scan(args.root, markers)
    for path, lineno, marker, line in hits:
        print(path + ":" + str(lineno) + " [" + marker + "] " + line)
    print(str(len(hits)) + " marker(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
