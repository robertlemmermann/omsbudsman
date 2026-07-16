#!/usr/bin/env python3
"""Summarize a unified diff without pasting it: files touched, +/- counts.

Usage: git diff | diffstat.py -     or     diffstat.py --git [ref]
"""
import argparse
import subprocess
import sys


def parse_diff(lines):
    files = {}
    current = None
    for line in lines:
        if line.startswith("+++ "):
            name = line[4:].strip()
            if name.startswith("b/"):
                name = name[2:]
            if name == "/dev/null":
                continue
            current = name
            files.setdefault(current, {"added": 0, "removed": 0})
        elif line.startswith("--- "):
            continue
        elif current and line.startswith("+") and not line.startswith("+++"):
            files[current]["added"] += 1
        elif current and line.startswith("-") and not line.startswith("---"):
            files[current]["removed"] += 1
    return files


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("source", nargs="?", default="-",
                        help="'-' for stdin (default)")
    parser.add_argument("--git", nargs="?", const="", metavar="REF",
                        help="run `git diff [REF]` itself")
    args = parser.parse_args(argv)

    if args.git is not None:
        cmd = ["git", "diff"] + ([args.git] if args.git else [])
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode != 0:
            print("diffstat: git diff failed: " + proc.stderr.strip(), file=sys.stderr)
            return 1
        lines = proc.stdout.splitlines()
    else:
        lines = sys.stdin.read().splitlines()

    files = parse_diff(lines)
    total_added = sum(f["added"] for f in files.values())
    total_removed = sum(f["removed"] for f in files.values())
    for name, stats in sorted(files.items()):
        print(name + ": +" + str(stats["added"]) + " -" + str(stats["removed"]))
    print(str(len(files)) + " file(s), +" + str(total_added)
          + " -" + str(total_removed))
    return 0


if __name__ == "__main__":
    sys.exit(main())
