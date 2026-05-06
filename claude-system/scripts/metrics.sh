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
#   metrics.sh --exclude-outliers    # drop top/bottom 5% before averaging
#   metrics.sh --histograms          # text-mode 10-bucket bars per agent
#   metrics.sh --check               # exit non-zero if last-7-days tokens-per-task
#                                    # exceeds BASELINE by --regress-pct (default 20%)
#   metrics.sh --regress-pct <N>     # regression threshold as a percent (default 20)
#
# Pricing is read from $CLAUDE_HOME/scripts/pricing.json (auto-updated on install).
# If absent, a small embedded fallback table is used.
set -euo pipefail

GLOBAL_ROOT="${LIBRARIAN_GLOBAL_ROOT:-${CLAUDE_HOME:-$HOME/.claude}}"
JSONL="$GLOBAL_ROOT/metrics/sessions.jsonl"
BASELINE="$GLOBAL_ROOT/metrics/BASELINE.md"
PRICING_JSON="$GLOBAL_ROOT/scripts/pricing.json"
# Fall back to the in-repo copy if the installed copy isn't there yet (running
# from a fresh checkout before install).
if [ ! -f "$PRICING_JSON" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -f "$SCRIPT_DIR/pricing.json" ]; then
    PRICING_JSON="$SCRIPT_DIR/pricing.json"
  fi
fi

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
EXCLUDE_OUTLIERS=0
HISTOGRAMS=0
REGRESS_PCT=20

while [ $# -gt 0 ]; do
  case "$1" in
    --agent)             MODE="agent";    ARG="${2:-}"; shift 2;;
    --session)           MODE="session";  ARG="${2:-}"; shift 2;;
    --baseline)          MODE="baseline"; shift;;
    --json)              MODE="json";     shift;;
    --check)             MODE="check";    shift;;
    --days)              DAYS="${2:-7}"; shift 2;;
    --exclude-outliers)  EXCLUDE_OUTLIERS=1; shift;;
    --histograms)        HISTOGRAMS=1; shift;;
    --regress-pct)       REGRESS_PCT="${2:-20}"; shift 2;;
    -h|--help)           sed -n '2,20p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

python3 - "$JSONL" "$BASELINE" "$MODE" "$ARG" "$DAYS" "$PRICING_JSON" "$EXCLUDE_OUTLIERS" "$HISTOGRAMS" "$REGRESS_PCT" <<'PY'
import json, sys, datetime, statistics, pathlib

jsonl_path       = pathlib.Path(sys.argv[1])
baseline         = pathlib.Path(sys.argv[2])
mode             = sys.argv[3]
arg              = sys.argv[4]
days             = int(sys.argv[5])
pricing_path     = pathlib.Path(sys.argv[6]) if sys.argv[6] else None
exclude_outliers = sys.argv[7] == "1"
histograms       = sys.argv[8] == "1"
regress_pct      = float(sys.argv[9])

# Pricing per 1M tokens (input / output). Sourced from pricing.json so users
# can update without editing this script. Embedded fallback for stale installs.
EMBEDDED_PRICING = {
    "claude-opus-4-7":            (15.00, 75.00),
    "claude-opus-4-6":            (15.00, 75.00),
    "claude-sonnet-4-6":          ( 3.00, 15.00),
    "claude-haiku-4-5":           ( 1.00,  5.00),
    "claude-haiku-4-5-20251001":  ( 1.00,  5.00),
}
EMBEDDED_DEFAULT = (3.00, 15.00)

PRICING = dict(EMBEDDED_PRICING)
DEFAULT_PRICE = EMBEDDED_DEFAULT
PRICING_AGE_WARNING = None
if pricing_path and pricing_path.is_file():
    try:
        data = json.loads(pricing_path.read_text())
        models = data.get("models") or {}
        if isinstance(models, dict):
            PRICING = {k: tuple(v) for k, v in models.items() if isinstance(v, list) and len(v) == 2}
        if isinstance(data.get("default"), list) and len(data["default"]) == 2:
            DEFAULT_PRICE = tuple(data["default"])
        last_updated = data.get("last_updated")
        if last_updated:
            try:
                d = datetime.datetime.strptime(last_updated, "%Y-%m-%d").replace(tzinfo=datetime.timezone.utc)
                age = (datetime.datetime.now(datetime.timezone.utc) - d).days
                if age > 90:
                    PRICING_AGE_WARNING = f"pricing.json is {age} days old — refresh against Anthropic's current rates."
            except ValueError:
                pass
    except (OSError, json.JSONDecodeError, ValueError):
        pass

def cost(model, input_tokens, output_tokens):
    rates = PRICING.get(model or "", DEFAULT_PRICE)
    return (input_tokens or 0) / 1e6 * rates[0] + (output_tokens or 0) / 1e6 * rates[1]

def trim_outliers(xs):
    """Drop the top and bottom 5% before averaging."""
    if not xs or len(xs) < 20:
        return xs
    s = sorted(xs)
    drop = max(1, int(round(len(s) * 0.05)))
    return s[drop:-drop]

def histogram(xs, buckets=10, width=30):
    """Return a list of bar strings showing the distribution of xs."""
    if not xs:
        return []
    lo, hi = min(xs), max(xs)
    if lo == hi:
        return [f"  [{lo}]: {len(xs)}"]
    step = (hi - lo) / buckets
    counts = [0] * buckets
    for x in xs:
        idx = min(buckets - 1, int((x - lo) / step))
        counts[idx] += 1
    cmax = max(counts) or 1
    out = []
    for i, c in enumerate(counts):
        bar = "█" * int(round(c / cmax * width))
        edge_lo = int(lo + i * step)
        edge_hi = int(lo + (i + 1) * step)
        out.append(f"  {edge_lo:>6}-{edge_hi:<6} {bar} {c}")
    return out

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
    inp_raw = [r["input_tokens"]  for r in rs if isinstance(r.get("input_tokens"),  (int,float))]
    out_raw = [r["output_tokens"] for r in rs if isinstance(r.get("output_tokens"), (int,float))]
    inp = trim_outliers(inp_raw) if exclude_outliers else inp_raw
    out = trim_outliers(out_raw) if exclude_outliers else out_raw
    cr  = [r["cache_read_tokens"] or 0 for r in rs]
    blocked = sum(1 for r in rs if r.get("blocked"))
    cache_rate = sum(cr) / sum(inp_raw) if sum(inp_raw) else None
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
    result = {
        "agent": name,
        "calls": len(rs),
        "input":  stat(inp),
        "output": stat(out),
        "cache_hit_rate": round(cache_rate, 3) if cache_rate is not None else None,
        "blocked_rate":   round(blocked / len(rs), 3),
        "total_cost_usd": round(total_cost, 4),
    }
    if histograms:
        result["output_histogram"] = histogram(out_raw)
    return result

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
    if exclude_outliers:
        lines.append("(top/bottom 5% trimmed from input/output stats)")
    if PRICING_AGE_WARNING:
        lines.append(f"WARNING: {PRICING_AGE_WARNING}")
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
        if histograms and a.get("output_histogram"):
            lines.append(f"    output-token distribution:")
            lines.extend("    " + h for h in a["output_histogram"])
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

def tokens_per_task(sessions):
    if not sessions:
        return None
    totals = []
    for s in sessions:
        ti = s.get("total_input_tokens")  or 0
        to = s.get("total_output_tokens") or 0
        if ti or to:
            totals.append(ti + to)
    if not totals:
        return None
    if exclude_outliers:
        totals = trim_outliers(totals)
    if not totals:
        return None
    return statistics.fmean(totals)

if mode == "check":
    # Cost regression alarm: compare last-7-days mean tokens-per-task against
    # the value frozen in BASELINE.md (line: "BASELINE_TOKENS_PER_TASK: <n>").
    cur = tokens_per_task(sessions)
    baseline_value = None
    if baseline.is_file():
        for line in baseline.read_text().splitlines():
            line = line.strip()
            if line.startswith("BASELINE_TOKENS_PER_TASK:"):
                try:
                    baseline_value = float(line.split(":", 1)[1].strip())
                except ValueError:
                    baseline_value = None
                break
    if cur is None:
        print("no recent sessions to check")
        sys.exit(0)
    if baseline_value is None:
        print(f"current mean tokens/task: {cur:.0f} (no BASELINE_TOKENS_PER_TASK set; run --baseline first)")
        sys.exit(0)
    drift = (cur - baseline_value) / baseline_value * 100
    print(f"baseline tokens/task: {baseline_value:.0f}  current: {cur:.0f}  drift: {drift:+.1f}%  (threshold: {regress_pct:.0f}%)")
    if drift > regress_pct:
        print("REGRESSION: tokens/task drifted above the configured threshold.")
        sys.exit(1)
    sys.exit(0)

if mode == "baseline":
    text = render_text(summary)
    tpt = tokens_per_task(sessions)
    tpt_line = f"BASELINE_TOKENS_PER_TASK: {tpt:.0f}\n" if tpt is not None else "BASELINE_TOKENS_PER_TASK: (no data)\n"
    body = (
        "# Baseline metrics\n\n"
        f"> Generated: {datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%d %H:%M:%SZ')} from "
        f"{summary['session_count']} sessions / {summary['subagent_calls']} subagent calls "
        f"over the last {days} days.\n\n"
        + tpt_line +
        "\nReading guide:\n"
        "- `out_mean` is the average output-token count per call. Tighten the agent's cap if it drifts up.\n"
        "- `cache` is the cache-hit rate on input tokens. Low rates mean the system prompt is varying.\n"
        "- `blocked` is the rate of `BLOCKED` returns. Very high → pre-flight is too strict, or the planner is dispatching wrong.\n"
        "- `$` is best-effort using $CLAUDE_HOME/scripts/pricing.json — refresh that file when Anthropic changes prices.\n"
        "- `BASELINE_TOKENS_PER_TASK` is read by `metrics.sh --check` to flag regressions above the configured threshold.\n\n"
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
