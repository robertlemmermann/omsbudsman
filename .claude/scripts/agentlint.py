#!/usr/bin/env python3
"""Static checks for agent definition files (plan §8.1 static layer).

Per agent file:
  - YAML-ish frontmatter present with name, description, model.
  - name matches the filename.
  - model is a known tier alias (haiku/sonnet/opus/inherit) or a claude-* id.
  - an explicit tools: grant is present (omitting it inherits everything).
  - an output cap is declared ("Cap:" appears in the body).
  - a pre-flight / BLOCKED contract is present.
  - file length ≤ 250 lines.
  - cache-safe ordering: frontmatter + stable identity first (no templated
    volatile content — checked as: no "{{" placeholders anywhere).

Usage: agentlint.py <agents-dir> [--quiet]   (exit 0 clean, 1 findings)
"""
import argparse
import re
import sys
from pathlib import Path

VALID_MODELS = {"haiku", "sonnet", "opus", "inherit"}
MAX_LINES = 250
# The orchestrator is the main-session persona: it must never inherit file
# tools, but it is allowed Task+Bash. Everyone else needs an explicit grant too.


def parse_frontmatter(text):
    if not text.startswith("---"):
        return None, "missing frontmatter"
    end = text.find("\n---", 3)
    if end < 0:
        return None, "unterminated frontmatter"
    fm = {}
    for line in text[3:end].strip().splitlines():
        if ":" in line:
            key, _, value = line.partition(":")
            fm[key.strip()] = value.strip()
    return fm, None


def lint_file(path):
    findings = []
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()

    fm, err = parse_frontmatter(text)
    if err:
        return [err]

    name = fm.get("name", "")
    if not name:
        findings.append("frontmatter missing name")
    elif name != path.stem:
        findings.append("name '" + name + "' != filename '" + path.stem + "'")
    if not fm.get("description"):
        findings.append("frontmatter missing description")

    model = fm.get("model", "")
    if not model:
        findings.append("frontmatter missing model")
    elif model not in VALID_MODELS and not model.startswith("claude-"):
        findings.append("unknown model tier: " + model)

    if "tools" not in fm:
        findings.append("no tools: grant — omitting it inherits every tool")
    elif not fm["tools"]:
        findings.append("empty tools: grant fails to launch")

    if len(lines) > MAX_LINES:
        findings.append("file is " + str(len(lines)) + " lines (max "
                        + str(MAX_LINES) + ")")

    body = text.lower()
    if "cap:" not in body:
        findings.append("no output cap declared (expected a 'Cap:' rule)")
    if "blocked" not in body:
        findings.append("no BLOCKED pre-flight contract")
    if re.search(r"\{\{[^}]*\}\}", text):
        findings.append("template placeholder present — breaks stable prompt prefix")
    if re.search(r"~/\.claude/(?!memory)", text):
        findings.append("hard ~/.claude path (only the optional memory tier may reference it)")
    return findings


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("agents_dir")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args(argv)

    agents_dir = Path(args.agents_dir)
    files = sorted(agents_dir.glob("*.md"))
    if not files:
        print("agentlint: no agent files under " + str(agents_dir))
        return 1

    total = 0
    for path in files:
        findings = lint_file(path)
        total += len(findings)
        for finding in findings:
            print("agentlint: " + path.name + ": " + finding)
    if not args.quiet:
        print("agentlint: " + str(len(files)) + " files, "
              + str(total) + " finding(s)")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
