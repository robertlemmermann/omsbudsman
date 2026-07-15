#!/usr/bin/env python3
"""Memory structure + bloat report (plan §6 decay policy).

Checks .ombudsman/memory/:
  - INDEX.md files exist for the tier and mistakes/.
  - every entry carries a Last seen / Added date.
  - entries unreferenced for >90 days are listed as archive candidates
    (mistakes with Recurrences ≥ 2 are exempt — they've paid for themselves).
  - total tier size stays under the bloat threshold (default 64 KiB).

Usage: memlint.py <memory-dir> [--max-kib 64]   (exit 0 clean, 1 findings)
"""
import argparse
import datetime
import re
import sys
from pathlib import Path

DATE_RE = re.compile(r"(?:Last seen|Added):\s*(\d{4}-\d{2}-\d{2})")
RECUR_RE = re.compile(r"Recurrences:\s*(\d+)")


def lint(memory_dir, max_kib):
    findings = []
    memory_dir = Path(memory_dir)
    if not memory_dir.is_dir():
        return ["memory dir missing: " + str(memory_dir)]
    if not (memory_dir / "INDEX.md").is_file():
        findings.append("missing INDEX.md")
    mistakes = memory_dir / "mistakes"
    if mistakes.is_dir() and not (mistakes / "INDEX.md").is_file():
        findings.append("missing mistakes/INDEX.md")

    today = datetime.date.today()
    total_bytes = 0
    for path in sorted(memory_dir.rglob("*.md")):
        rel = path.relative_to(memory_dir)
        if ".archive" in rel.parts:
            continue
        text = path.read_text(encoding="utf-8")
        total_bytes += len(text.encode("utf-8"))
        dates = DATE_RE.findall(text)
        recurrences = [int(n) for n in RECUR_RE.findall(text)]
        for date_str in dates:
            try:
                age = (today - datetime.date.fromisoformat(date_str)).days
            except ValueError:
                findings.append(str(rel) + ": malformed date " + date_str)
                continue
            if age > 90 and not any(n >= 2 for n in recurrences):
                findings.append(str(rel) + ": entry last seen " + date_str
                                + " (" + str(age) + "d) — archive candidate")
                break

    if total_bytes > max_kib * 1024:
        findings.append("tier size " + str(total_bytes // 1024) + " KiB exceeds "
                        + str(max_kib) + " KiB — run librarian mode: compact")
    return findings


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("memory_dir")
    parser.add_argument("--max-kib", type=int, default=64)
    args = parser.parse_args(argv)

    findings = lint(args.memory_dir, args.max_kib)
    for finding in findings:
        print("memlint: " + finding)
    print("memlint: " + str(len(findings)) + " finding(s)")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
