#!/usr/bin/env python3
"""Static safety checks for hook files (plan §10 — gap G9).

Per hook file (.claude/hooks/*.py, excluding _common.py which is checked
for a subset):
  - a no-fail wrapper is present (_common.run(...) or a bare except guard).
  - no execution of repo-controlled content: no eval/exec/os.system,
    no subprocess with shell=True.
  - JSON is built with json.dumps / json.dump only (no hand-concatenated
    '{"...' strings).
  - paths are self-derived: no hardcoded ~/.claude outside an explicit
    optional-global-memory reference; no reliance on inherited LIBRARIAN_*
    env vars.
  - the file compiles.

Usage: hooklint.py <hooks-dir> [--quiet]   (exit 0 clean, 1 findings)
"""
import argparse
import ast
import re
import sys
from pathlib import Path

FORBIDDEN_CALLS = {"eval", "exec"}


def lint_file(path):
    findings = []
    text = path.read_text(encoding="utf-8")

    try:
        tree = ast.parse(text)
    except SyntaxError as exc:
        return ["does not compile: " + str(exc)]

    for node in ast.walk(tree):
        if isinstance(node, ast.Call):
            func = node.func
            name = getattr(func, "id", None) or getattr(func, "attr", None)
            if name in FORBIDDEN_CALLS:
                findings.append("forbidden call: " + name + "()")
            if name == "system" and getattr(getattr(func, "value", None), "id", "") == "os":
                findings.append("forbidden call: os.system()")
            for kw in node.keywords or []:
                if kw.arg == "shell" and isinstance(kw.value, ast.Constant) \
                        and kw.value.value is True:
                    findings.append("subprocess with shell=True")

    is_common = path.name == "_common.py"
    if not is_common:
        if "_common.run(" not in text and "except Exception" not in text:
            findings.append("no no-fail wrapper (_common.run or catch-all except)")
        if re.search(r"os\.environ\.get\(['\"]LIBRARIAN_", text):
            findings.append("relies on inherited LIBRARIAN_* env vars (they don't propagate)")

    if re.search(r'["\']\s*\{\s*\\?["\']\w+\\?["\']\s*:', text):
        findings.append("hand-concatenated JSON literal — use json.dumps")
    for match in re.finditer(r"~/\.claude/\S*", text):
        if "memory" not in match.group(0):
            findings.append("hardcoded ~/.claude path: " + match.group(0))
    return findings


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("hooks_dir")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args(argv)

    hooks_dir = Path(args.hooks_dir)
    files = sorted(hooks_dir.glob("*.py"))
    if not files:
        print("hooklint: no hook files under " + str(hooks_dir))
        return 1

    total = 0
    for path in files:
        findings = lint_file(path)
        total += len(findings)
        for finding in findings:
            print("hooklint: " + path.name + ": " + finding)
    if not args.quiet:
        print("hooklint: " + str(len(files)) + " files, "
              + str(total) + " finding(s)")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
