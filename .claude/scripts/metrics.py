#!/usr/bin/env python3
"""Telemetry reporting over .claude/metrics/sessions.jsonl plus transcript
files, with cost estimates from pricing.json.

Runtime JSONL carries only fields that exist in hook payloads (no token
counts — see plan §7); token/cost reporting requires transcript files
captured by the harness or by `claude -p --output-format stream-json`.

Usage:
  metrics.py summary [--root DIR]                 # session/agent counts, gates
  metrics.py cost <transcript.jsonl> [...]        # real token cost from transcripts
  metrics.py --trend [--root DIR]                 # per-class medians vs baseline.json
"""
import argparse
import datetime
import json
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import transcript as transcript_mod  # noqa: E402


def load_jsonl(path):
    records = []
    try:
        with Path(path).open(encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(obj, dict):
                    records.append(obj)
    except OSError:
        pass
    return records


def load_pricing():
    path = HERE / "pricing.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {"default": [3.0, 15.0], "models": {}, "last_updated": None}
    updated = data.get("last_updated")
    if updated:
        try:
            age = (datetime.date.today()
                   - datetime.date.fromisoformat(updated)).days
            if age > 90:
                print("warning: pricing.json is " + str(age)
                      + " days old — verify current rates", file=sys.stderr)
        except ValueError:
            pass
    return data


def price_for(pricing, model):
    models = pricing.get("models") or {}
    if model in models:
        return models[model]
    for known, rate in models.items():
        if model and model.startswith(known):
            return rate
    return pricing.get("default", [3.0, 15.0])


def cmd_summary(root):
    records = load_jsonl(Path(root) / ".claude" / "metrics" / "sessions.jsonl")
    sessions = [r for r in records if r.get("kind") == "session"]
    subagents = [r for r in records if r.get("kind") == "subagent"]
    flags = [r for r in records if r.get("kind") == "cost_flag"]

    print("sessions: " + str(len(sessions)))
    print("subagent dispatches: " + str(len(subagents)))
    blocked = sum(1 for r in subagents if r.get("blocked"))
    if subagents:
        print("blocked rate: " + str(round(blocked / len(subagents), 3)))
    by_agent = {}
    for r in subagents:
        by_agent[r.get("agent") or "(unknown)"] = by_agent.get(r.get("agent") or "(unknown)", 0) + 1
    for agent, count in sorted(by_agent.items(), key=lambda kv: -kv[1]):
        print("  " + agent + ": " + str(count))
    verdicts = [s.get("auditor_verdict") for s in sessions if s.get("auditor_verdict")]
    if verdicts:
        print("auditor verdicts: " + ", ".join(verdicts))
    if flags:
        print("cost flags: " + str(len(flags)))
    return 0


def cmd_cost(paths):
    pricing = load_pricing()
    grand_total = 0.0
    for path in paths:
        metrics = transcript_mod.parse_file(path)
        cost = 0.0
        for model, stats in metrics["models"].items():
            rate_in, rate_out = price_for(pricing, model)
            cost += stats["output_tokens"] / 1e6 * rate_out
        # Input priced at the blended default when multiple models share a
        # transcript — per-model input split is not present in usage blocks.
        rate_in = price_for(pricing, next(iter(metrics["models"]), None))[0]
        cost += metrics["input_tokens"] / 1e6 * rate_in
        cost += metrics["cache_read_input_tokens"] / 1e6 * rate_in * 0.1
        grand_total += cost
        print(Path(path).name + ": $" + format(cost, ".4f")
              + "  (in=" + str(metrics["input_tokens"])
              + " out=" + str(metrics["output_tokens"])
              + " cache_read=" + str(metrics["cache_read_input_tokens"]) + ")")
    print("total: $" + format(grand_total, ".4f"))
    return 0


def cmd_trend(root):
    metrics_dir = Path(root) / ".claude" / "metrics"
    records = load_jsonl(metrics_dir / "sessions.jsonl")
    sessions = [r for r in records if r.get("kind") == "session"]
    by_class = {}
    for s in sessions:
        cls = s.get("task_class") or "other"
        count = s.get("subagent_count")
        if isinstance(count, (int, float)):
            by_class.setdefault(cls, []).append(count)

    baseline = None
    baseline_path = metrics_dir / "baseline.json"
    if baseline_path.is_file():
        try:
            baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            baseline = None

    drifted = False
    for cls, counts in sorted(by_class.items()):
        median = statistics.median(counts)
        line = cls + ": median_subagents=" + str(median) + " (n=" + str(len(counts)) + ")"
        base = ((baseline or {}).get("classes") or {}).get(cls, {}).get("median_subagents")
        if isinstance(base, (int, float)) and base > 0:
            drift = (median - base) / base
            line += "  baseline=" + str(base) + " drift=" + format(drift, "+.0%")
            if abs(drift) > 0.2:
                line += "  ← DRIFT >20%"
                drifted = True
        print(line)
    if not by_class:
        print("no session records yet")
    return 1 if drifted else 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--trend", action="store_true")
    parser.add_argument("--root", default=".")
    parser.add_argument("command", nargs="?", choices=["summary", "cost"])
    parser.add_argument("paths", nargs="*")
    args = parser.parse_args(argv)

    if args.trend:
        return cmd_trend(args.root)
    if args.command == "cost":
        if not args.paths:
            parser.error("cost requires at least one transcript path")
        return cmd_cost(args.paths)
    return cmd_summary(args.root)


if __name__ == "__main__":
    sys.exit(main())
