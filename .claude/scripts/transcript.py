#!/usr/bin/env python3
"""Transcript parser — the ONLY accurate token-measurement layer (plan §7).

Parses `claude -p --output-format stream-json --verbose` output (one JSON
object per line) and aggregates real usage: input/output tokens, cache-read
vs cache-creation, model per call, Task routing, and BLOCKED returns.

Usage: transcript.py <transcript.jsonl> [--json]
Shared by the harness (per-trial metrics.json) and metrics.py.
"""
import argparse
import json
import sys
from pathlib import Path


def parse_lines(lines):
    """Aggregate a stream-json transcript. Returns a metrics dict."""
    totals = {
        "input_tokens": 0,
        "output_tokens": 0,
        "cache_read_input_tokens": 0,
        "cache_creation_input_tokens": 0,
    }
    models = {}
    task_dispatches = []
    blocked_returns = 0
    num_turns = None
    result_usage_seen = False

    for raw in lines:
        raw = raw.strip()
        if not raw:
            continue
        try:
            event = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if not isinstance(event, dict):
            continue

        etype = event.get("type")
        message = event.get("message") if isinstance(event.get("message"), dict) else None

        usage = None
        model = None
        if message:
            usage = message.get("usage") if isinstance(message.get("usage"), dict) else None
            model = message.get("model")
        if etype == "result":
            num_turns = event.get("num_turns", num_turns)
            r_usage = event.get("usage")
            if isinstance(r_usage, dict):
                usage = r_usage
                result_usage_seen = True

        if usage:
            for key in totals:
                val = usage.get(key)
                if isinstance(val, (int, float)):
                    totals[key] += val
            if model:
                m = models.setdefault(model, {"calls": 0, "output_tokens": 0})
                m["calls"] += 1
                out = usage.get("output_tokens")
                if isinstance(out, (int, float)):
                    m["output_tokens"] += out

        # Task dispatches → routing; BLOCKED text → blocked-rate.
        content = (message or {}).get("content")
        if isinstance(content, list):
            for block in content:
                if not isinstance(block, dict):
                    continue
                # The subagent-dispatch tool is named "Task" in older CLIs
                # and "Agent" in 2.x — count both.
                if block.get("type") == "tool_use" and block.get("name") in ("Task", "Agent"):
                    ti = block.get("input") or {}
                    task_dispatches.append(ti.get("subagent_type") or "unknown")
                text = block.get("text") or (
                    block.get("content") if isinstance(block.get("content"), str) else ""
                )
                if isinstance(text, str) and text.lstrip().upper().startswith("BLOCKED"):
                    blocked_returns += 1

    fresh_input = totals["input_tokens"]
    cache_read = totals["cache_read_input_tokens"]
    denominator = fresh_input + cache_read
    return {
        "input_tokens": fresh_input,
        "output_tokens": totals["output_tokens"],
        "cache_read_input_tokens": cache_read,
        "cache_creation_input_tokens": totals["cache_creation_input_tokens"],
        "cache_hit_rate": round(cache_read / denominator, 3) if denominator else None,
        "models": models,
        "task_dispatches": task_dispatches,
        "subagent_count": len(task_dispatches),
        "blocked_returns": blocked_returns,
        "num_turns": num_turns,
        "usage_source": "result" if result_usage_seen else "messages",
    }


def parse_file(path):
    with Path(path).open(encoding="utf-8") as f:
        return parse_lines(f)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("transcript")
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    args = parser.parse_args(argv)

    metrics = parse_file(args.transcript)
    if args.json:
        print(json.dumps(metrics, indent=2))
        return 0
    print("tokens: in=" + str(metrics["input_tokens"])
          + " out=" + str(metrics["output_tokens"])
          + " cache_read=" + str(metrics["cache_read_input_tokens"])
          + " cache_create=" + str(metrics["cache_creation_input_tokens"]))
    print("cache_hit_rate: " + str(metrics["cache_hit_rate"]))
    print("subagents: " + (", ".join(metrics["task_dispatches"]) or "(none)"))
    print("blocked_returns: " + str(metrics["blocked_returns"]))
    for model, stats in metrics["models"].items():
        print("model " + model + ": " + str(stats["calls"]) + " calls, "
              + str(stats["output_tokens"]) + " out-tokens")
    return 0


if __name__ == "__main__":
    sys.exit(main())
