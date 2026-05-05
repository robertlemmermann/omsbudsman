#!/usr/bin/env bash
# Phase 6: report metrics from ~/.claude/metrics/sessions.jsonl.
#
# Usage:
#   metrics.sh                       # last 7 days summary
#   metrics.sh --agent <name>        # per-agent breakdown
#   metrics.sh --session <id>        # one session's flow
#   metrics.sh --baseline            # write/update metrics/BASELINE.md
#   metrics.sh --json                # raw JSON of the summary (for scripts)
#   metrics.sh --days <N>            # restrict window to N days (default 7)
#
# Pricing (USD per 1M tokens; input / output) — update when Anthropic changes them.
set -euo pipefail

GLOBAL_ROOT="${LIBRARIAN_GLOBAL_ROOT:-${CLAUDE_HOME:-$HOME/.claude}}"
JSONL="$GLOBAL_ROOT/metrics/sessions.jsonl"
BASELINE="$GLOBAL_ROOT/metrics/BASELINE.md"

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required for metrics reporting." >&2
  exit 1
fi

if [ ! -f "$JSONL" ]; then
  echo "No metrics yet at $JSONL"
  exit 0
fi

MODE="summary"
ARG=""
DAYS=7

while [ $# -gt 0 ]; do
  case "$1" in
    --agent)    MODE="agent";    ARG="${2:-}"; shift 2;;
    --session)  MODE="session";  ARG="${2:-}"; shift 2;;
    --baseline) MODE="baseline"; shift;;
    --json)     MODE="json";     shift;;
    --days)     DAYS="${2:-7}"; shift 2;;
    -h|--help)  sed -n '2,12p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

python3 - "$JSONL" "$BASELINE" "$MODE" "$ARG" "$DAYS" <<'PY'
import json, sys, datetime, statistics, pathlib

jsonl_path  = pathlib.Path(sys.argv[1])
baseline    = pathlib.Path(sys.argv[2])
mode        = sys.argv[3]
arg         = sys.argv[4]
days        = int(sys.argv[5])

# Pricing per 1M tokens (input / output). Update when Anthropic changes them.
PRICING = {
    "claude-opus-4-7":      (15.00, 75.00),
    "claude-opus-4-6":      (15.00, 75.00),
    "claude-sonnet-4-6":    ( 3.00, 15.00),
    "claude-haiku-4-5":     ( 1.00,  5.00),
    "claude-haiku-4-5-20251001": (1.00, 5.00),
}
DEFAULT_PRICE = (3.00, 15.00)  # sonnet-class fallback

def cost(model, input_tokens, output_tokens):
    rates = PRICING.get(model or "", DEFAULT_PRICE)
    return (input_tokens or 0) / 1e6 * rates[0] + (output_tokens or 0) / 1e6 * rates[1]

def parse_ts(s):
    if not s:
        return None
    try:
        return datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    except ValueError:
        return None

cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=days)

records = []
with jsonl_path.open() as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            continue
        ts = parse_ts(r.get("ts"))
        if mode in ("session",) or (ts and ts >= cutoff) or mode == "baseline":
            records.append(r)

subagents = [r for r in records if r.get("kind") == "subagent"]
sessions  = [r for r in records if r.get("kind") == "session"]

def summarize_agent(name):
    rs = [r for r in subagents if r.get("agent") == name]
    if not rs:
        return None
    inp = [r["input_tokens"]  for r in rs if isinstance(r.get("input_tokens"),  (int,float))]
    out = [r["output_tokens"] for r in rs if isinstance(r.get("output_tokens"), (int,float))]
    cr  = [r["cache_read_tokens"] or 0 for r in rs]
    blocked = sum(1 for r in rs if r.get("blocked"))
    cache_rate = sum(cr) / sum(inp) if sum(inp) else None
    def stat(xs):
        if not xs: return None
        s = sorted(xs)
        return {
            "n": len(xs),
            "mean": round(statistics.fmean(xs), 1),
            "p50": s[len(s)//2],
            "p95": s[min(len(s)-1, int(round(len(s)*0.95))-1 if len(s)>1 else 0)],
        }
    total_cost = sum(cost(r.get("model"), r.get("input_tokens") or 0, r.get("output_tokens") or 0) for r in rs)
    return {
        "agent": name,
        "calls": len(rs),
        "input":  stat(inp),
        "output": stat(out),
        "cache_hit_rate": round(cache_rate, 3) if cache_rate is not None else None,
        "blocked_rate":   round(blocked / len(rs), 3),
        "total_cost_usd": round(total_cost, 4),
    }

def summarize_overall():
    agents = sorted({r.get("agent") for r in subagents if r.get("agent")})
    by_agent = [summarize_agent(a) for a in agents]
    by_agent = [a for a in by_agent if a]

    by_class = {}
    for s in sessions:
        c = s.get("task_class") or "other"
        by_class.setdefault(c, []).append(s)

    class_summary = {}
    for c, ss in sorted(by_class.items()):
        in_t  = [s["total_input_tokens"]  for s in ss if isinstance(s.get("total_input_tokens"),  (int,float))]
        out_t = [s["total_output_tokens"] for s in ss if isinstance(s.get("total_output_tokens"), (int,float))]
        class_summary[c] = {
            "sessions":     len(ss),
            "mean_input":   round(statistics.fmean(in_t),  1) if in_t  else None,
            "mean_output":  round(statistics.fmean(out_t), 1) if out_t else None,
        }

    qa_pass = [s["qa_pass_rate"] for s in sessions if isinstance(s.get("qa_pass_rate"), (int,float))]
    auditor_verdicts = [s.get("auditor_verdict") for s in sessions if s.get("auditor_verdict")]

    retro_triggered = sum(1 for s in sessions if s.get("retro_triggered"))
    mistakes_total  = sum(int(s.get("mistakes_recorded") or 0) for s in sessions)
    retro_fp_rate   = None
    if retro_triggered:
        retro_fp_rate = round(1 - (mistakes_total / retro_triggered), 3)

    return {
        "window_days":     days,
        "session_count":   len(sessions),
        "subagent_calls":  len(subagents),
        "by_agent":        by_agent,
        "by_task_class":   class_summary,
        "qa_mean_pass_rate": round(statistics.fmean(qa_pass), 3) if qa_pass else None,
        "auditor_distribution": {v: auditor_verdicts.count(v) for v in sorted(set(auditor_verdicts))} if auditor_verdicts else {},
        "retro_triggered":  retro_triggered,
        "mistakes_recorded": mistakes_total,
        "retro_false_positive_rate": retro_fp_rate,
    }

def render_text(summary):
    lines = []
    lines.append(f"=== Multi-agent metrics — last {summary['window_days']} days ===")
    lines.append(f"Sessions: {summary['session_count']}    Subagent calls: {summary['subagent_calls']}")
    if summary["qa_mean_pass_rate"] is not None:
        lines.append(f"QA mean pass rate: {summary['qa_mean_pass_rate']:.0%}")
    if summary["auditor_distribution"]:
        ad = "  ".join(f"{k}={v}" for k, v in summary["auditor_distribution"].items())
        lines.append(f"Auditor verdicts: {ad}")
    if summary["retro_triggered"]:
        fp = summary["retro_false_positive_rate"]
        fp_s = f"{fp:.0%}" if fp is not None else "n/a"
        lines.append(f"Retro: triggered {summary['retro_triggered']}, mistakes recorded {summary['mistakes_recorded']}, false-positive rate {fp_s}")
    lines.append("")
    lines.append("Per agent (calls, mean output tokens, cache hit, blocked %, $):")
    for a in summary["by_agent"]:
        out = a["output"]["mean"] if a["output"] else "—"
        ch  = f"{a['cache_hit_rate']:.0%}" if a['cache_hit_rate'] is not None else "n/a"
        lines.append(f"  {a['agent']:<22} n={a['calls']:>3}  out_mean={out:>6}  cache={ch:>4}  blocked={a['blocked_rate']:.0%}  ${a['total_cost_usd']:.4f}")
    lines.append("")
    lines.append("Per task class (sessions, mean input, mean output):")
    for c, v in summary["by_task_class"].items():
        lines.append(f"  {c:<10} n={v['sessions']:>3}  input_mean={v['mean_input']}  output_mean={v['mean_output']}")
    return "\n".join(lines)

def render_session(sid):
    rs = [r for r in subagents if r.get("session_id") == sid]
    sess = [s for s in sessions if s.get("session_id") == sid]
    if not rs and not sess:
        return f"No records for session {sid}"
    lines = [f"=== Session {sid} ==="]
    if sess:
        s = sess[-1]
        lines.append(f"task_class={s.get('task_class')}  subagents={s.get('subagent_count')}  cost-est needs --json")
        lines.append(f"input_tokens={s.get('total_input_tokens')}  output_tokens={s.get('total_output_tokens')}  cache_hit={s.get('cache_hit_rate')}")
        lines.append(f"auditor={s.get('auditor_verdict')}  qa_pass_rate={s.get('qa_pass_rate')}  retro={s.get('retro_triggered')}")
    lines.append("Subagent flow:")
    for r in rs:
        lines.append(f"  {r.get('ts','?')} {r.get('agent','?'):<22} model={r.get('model','?')}  in={r.get('input_tokens')}  out={r.get('output_tokens')}  blocked={r.get('blocked')}")
    return "\n".join(lines)

if mode == "session":
    if not arg:
        print("usage: --session <id>", file=sys.stderr); sys.exit(2)
    print(render_session(arg))
    sys.exit(0)

if mode == "agent":
    if not arg:
        print("usage: --agent <name>", file=sys.stderr); sys.exit(2)
    a = summarize_agent(arg)
    if not a:
        print(f"no calls for agent {arg}")
    else:
        print(json.dumps(a, indent=2))
    sys.exit(0)

summary = summarize_overall()

if mode == "json":
    print(json.dumps(summary, indent=2))
    sys.exit(0)

if mode == "baseline":
    text = render_text(summary)
    body = (
        "# Baseline metrics\n\n"
        f"> Generated: {datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%d %H:%M:%SZ')} from "
        f"{summary['session_count']} sessions / {summary['subagent_calls']} subagent calls "
        f"over the last {days} days.\n\n"
        "Reading guide:\n"
        "- `out_mean` is the average output-token count per call. Tighten the agent's cap if it drifts up.\n"
        "- `cache` is the cache-hit rate on input tokens. Low rates mean the system prompt is varying.\n"
        "- `blocked` is the rate of `BLOCKED` returns. Very high → pre-flight is too strict, or the planner is dispatching wrong.\n"
        "- `$` is best-effort using the pricing constants embedded in metrics.sh — update them when Anthropic changes prices.\n\n"
        "```\n" + text + "\n```\n"
    )
    baseline.parent.mkdir(parents=True, exist_ok=True)
    baseline.write_text(body)
    print(f"Wrote {baseline}")
    print()
    print(text)
    sys.exit(0)

print(render_text(summary))
PY
