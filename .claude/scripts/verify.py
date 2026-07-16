#!/usr/bin/env python3
"""Whole-suite verify gate — deterministic, zero model cost.

Discovers the project's test command and runs it. The orchestrator runs this
after the last QA pass and feeds the verbatim result to the auditor as
VERIFY RESULT; a failing result is an automatic `revise`.

Usage: verify.py [--root DIR] [--timeout SECONDS] [--dry-run]
Prints `VERIFY RESULT: pass|fail|skip (<command>)` plus the output tail.
Exit codes: 0 pass, 1 fail, 3 no test command found (skip).
"""
import argparse
import subprocess
import sys
from pathlib import Path


def discover(root):
    """Return (argv, reason) for the project's test command, or (None, why)."""
    root = Path(root)
    pkg = root / "package.json"
    if pkg.is_file():
        try:
            import json
            scripts = (json.loads(pkg.read_text(encoding="utf-8")) or {}).get("scripts") or {}
            if "test" in scripts:
                return (["npm", "test", "--silent"], "package.json scripts.test")
        except (OSError, ValueError):
            pass
    if (root / "pyproject.toml").is_file() or (root / "pytest.ini").is_file() \
            or (root / "setup.cfg").is_file():
        return ([sys.executable, "-m", "pytest", "-q"], "python project markers")
    if (root / "tests").is_dir() or (root / "test").is_dir():
        return (
            [sys.executable, "-m", "unittest", "discover", "-s",
             "tests" if (root / "tests").is_dir() else "test", "-v"],
            "tests/ directory (unittest)",
        )
    if (root / "Cargo.toml").is_file():
        return (["cargo", "test", "--quiet"], "Cargo.toml")
    if (root / "go.mod").is_file():
        return (["go", "test", "./..."], "go.mod")
    return (None, "no recognized test configuration")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=".")
    parser.add_argument("--timeout", type=int, default=600)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)

    cmd, reason = discover(args.root)
    if cmd is None:
        print("VERIFY RESULT: skip (" + reason + ")")
        return 3
    if args.dry_run:
        print("VERIFY RESULT: would run " + " ".join(cmd) + " (" + reason + ")")
        return 0

    try:
        proc = subprocess.run(
            cmd, cwd=args.root, capture_output=True, text=True, timeout=args.timeout,
        )
    except FileNotFoundError:
        print("VERIFY RESULT: skip (" + cmd[0] + " not available on this surface)")
        return 3
    except subprocess.TimeoutExpired:
        print("VERIFY RESULT: fail (timeout after " + str(args.timeout) + "s: "
              + " ".join(cmd) + ")")
        return 1

    verdict = "pass" if proc.returncode == 0 else "fail"
    print("VERIFY RESULT: " + verdict + " (" + " ".join(cmd) + ")")
    tail = ((proc.stdout or "") + (proc.stderr or "")).strip().splitlines()[-15:]
    for line in tail:
        print("  " + line)
    return 0 if proc.returncode == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
