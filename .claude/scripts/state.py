#!/usr/bin/env python3
"""Gate-state helper — the orchestrator's only way to touch its state file.

Replaces hand-written JSON heredocs (a verified source of silent corruption).

Usage:
  state.py --root <project-root> --session <id> init [--task-class CLASS] [--diff]
  state.py --root <project-root> --session <id> set-qa <pass|fail>
  state.py --root <project-root> --session <id> set-auditor <approve|revise|escalate>
  state.py --root <project-root> --session <id> set-retro <true|false>
  state.py --root <project-root> --session <id> set-class <CLASS>
  state.py --root <project-root> --session <id> set-diff <true|false>
  state.py --root <project-root> --session <id> get

CLASS ∈ question | plan | implement | trivial | conversational | fix | other.
Exit 0 on success with a one-line confirmation; exit 2 on bad usage.
"""
import argparse
import json
import os
import sys
import tempfile
from pathlib import Path

CLASSES = {"question", "plan", "implement", "trivial", "conversational", "fix", "other"}
QA = {"pass", "fail"}
AUDITOR = {"approve", "revise", "escalate"}


def state_path(root, session):
    return Path(root) / ".claude" / "state" / ("session-" + session + ".json")


def load(path, session):
    if path.is_file():
        try:
            obj = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(obj, dict):
                obj.setdefault("session_id", session)
                obj.setdefault("qa_verdicts", [])
                obj.setdefault("auditor_verdict", None)
                obj.setdefault("retro_needed", False)
                return obj
        except (OSError, json.JSONDecodeError):
            pass
    return {
        "session_id": session,
        "task_class": None,
        "qa_verdicts": [],
        "auditor_verdict": None,
        "diff_produced": False,
        "retro_needed": False,
        "retro_prompts": [],
    }


def save(path, state):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
        json.dump(state, f, indent=2)
        f.write("\n")
    os.replace(tmp, str(path))


def parse_bool(value):
    low = value.strip().lower()
    if low in ("true", "1", "yes"):
        return True
    if low in ("false", "0", "no"):
        return False
    raise SystemExit("expected true|false, got: " + value)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", required=True)
    parser.add_argument("--session", required=True)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_init = sub.add_parser("init")
    p_init.add_argument("--task-class", choices=sorted(CLASSES), default=None)
    p_init.add_argument("--diff", action="store_true")
    sub.add_parser("set-qa").add_argument("verdict", choices=sorted(QA))
    sub.add_parser("set-auditor").add_argument("verdict", choices=sorted(AUDITOR))
    sub.add_parser("set-retro").add_argument("value")
    sub.add_parser("set-class").add_argument("value", choices=sorted(CLASSES))
    sub.add_parser("set-diff").add_argument("value")
    sub.add_parser("get")

    args = parser.parse_args(argv)
    path = state_path(args.root, args.session)
    state = load(path, args.session)

    if args.cmd == "init":
        # Merge, never clobber — UserPromptSubmit may have written retro flags first.
        if args.task_class:
            state["task_class"] = args.task_class
        state["diff_produced"] = bool(args.diff)
        save(path, state)
        print("initialized: " + str(path))
    elif args.cmd == "set-qa":
        state["qa_verdicts"] = list(state.get("qa_verdicts") or []) + [args.verdict]
        save(path, state)
        print("qa_verdicts: " + ",".join(state["qa_verdicts"]))
    elif args.cmd == "set-auditor":
        state["auditor_verdict"] = args.verdict
        save(path, state)
        print("auditor_verdict: " + args.verdict)
    elif args.cmd == "set-retro":
        state["retro_needed"] = parse_bool(args.value)
        save(path, state)
        print("retro_needed: " + str(state["retro_needed"]).lower())
    elif args.cmd == "set-class":
        state["task_class"] = args.value
        save(path, state)
        print("task_class: " + args.value)
    elif args.cmd == "set-diff":
        state["diff_produced"] = parse_bool(args.value)
        save(path, state)
        print("diff_produced: " + str(state["diff_produced"]).lower())
    elif args.cmd == "get":
        print(json.dumps(state, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
