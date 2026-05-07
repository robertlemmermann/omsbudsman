#!/usr/bin/env bash
# Phase 4 + 5 + 6: enforce auditor + retrospective gates AND emit a per-session
# telemetry summary on clean exit.
#
# Read JSON from stdin (Claude Code Stop-hook contract). Look up the
# session-state file the orchestrator writes at each gate.
# Block clean termination if either:
#   (a) qa_verdicts is non-empty AND auditor_verdict is null  -> auditor missing
#   (b) retro_needed is true                                  -> retrospective missing
#
# Bypass gates: CLAUDE_SKIP_AUDIT=1.
# Bypass telemetry: CLAUDE_MULTIAGENT_NO_METRICS=1.
set -e

INPUT="$(cat 2>/dev/null || true)"
[ -z "$INPUT" ] && exit 0

if ! command -v python3 >/dev/null 2>&1; then
  exit 0
fi

GLOBAL_ROOT="${LIBRARIAN_GLOBAL_ROOT:-${CLAUDE_HOME:-$HOME/.claude}}"
PROJECT_ROOT="${LIBRARIAN_PROJECT_ROOT:-$(pwd)}"
STATE_DIR="$GLOBAL_ROOT/state"
METRICS_DIR="$GLOBAL_ROOT/metrics"
mkdir -p "$METRICS_DIR" 2>/dev/null || true

SKIP_AUDIT="${CLAUDE_SKIP_AUDIT:-0}"
NO_METRICS="${CLAUDE_MULTIAGENT_NO_METRICS:-0}"

python3 - "$STATE_DIR" "$METRICS_DIR" "$PROJECT_ROOT" "$SKIP_AUDIT" "$NO_METRICS" "$INPUT" <<'PY'
import json, sys, pathlib, datetime

state_dir   = pathlib.Path(sys.argv[1])
metrics_dir = pathlib.Path(sys.argv[2])
project_root = sys.argv[3]
skip_audit  = sys.argv[4] == "1"
no_metrics  = sys.argv[5] == "1"
raw         = sys.argv[6]

try:
    payload = json.loads(raw)
except json.JSONDecodeError:
    sys.exit(0)

if payload.get("stop_hook_active"):
    sys.exit(0)

session_id = payload.get("session_id")

if skip_audit and not no_metrics:
    skip_log = metrics_dir / "skip-audit.jsonl"
    ts = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    record = {"ts": ts, "session_id": session_id or None, "cwd": project_root}
    try:
        skip_log.parent.mkdir(parents=True, exist_ok=True)
        with skip_log.open("a") as f:
            f.write(json.dumps(record) + "\n")
    except OSError:
        pass

if not session_id:
    out = {
        "decision": "block",
        "reason": (
            "Stop hook: no session_id in payload — gate enforcement is OFF for this session. "
            "Set CLAUDE_SKIP_AUDIT=1 to suppress this warning."
        ),
    }
    print(json.dumps(out))
    sys.exit(0)

state_path = state_dir / f"session-{session_id}.json"
state = None
if state_path.is_file():
    try:
        state = json.loads(state_path.read_text())
    except (OSError, json.JSONDecodeError):
        state = None

# --- Gate enforcement ---
if state is not None and not skip_audit:
    qa_verdicts     = state.get("qa_verdicts") or []
    auditor_verdict = state.get("auditor_verdict")
    retro_needed    = bool(state.get("retro_needed"))

    reasons = []
    if qa_verdicts and auditor_verdict is None:
        reasons.append(
            "auditor not run — run the auditor agent against the original user "
            "request, the PLAN, all engineer CHANGES, and the QA verdicts before "
            "responding."
        )
    if retro_needed:
        reasons.append(
            "corrections happened this session — run the retrospective agent "
            "against retro_prompts + the recent assistant turns + GATE_OUTPUTS, "
            "then dispatch librarian (mode: append) with its payload (or clear "
            "retro_needed if the retrospective decides this was a false positive)."
        )

    if reasons:
        out = {
            "decision": "block",
            "reason": " | ".join(reasons) + " Set CLAUDE_SKIP_AUDIT=1 to bypass for this stop only.",
        }
        print(json.dumps(out))
        sys.exit(0)

# --- Per-session telemetry summary ---
if no_metrics:
    sys.exit(0)

# Aggregate this session's subagent records from the JSONL.
jsonl = metrics_dir / "sessions.jsonl"
sub_records = []
if jsonl.is_file():
    try:
        with jsonl.open() as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if obj.get("kind") == "subagent" and obj.get("session_id") == session_id:
                    sub_records.append(obj)
    except OSError:
        pass

# Skip the summary if no work was recorded this session — keeps the file clean.
if not sub_records and (state is None or not (state.get("qa_verdicts") or state.get("retro_needed"))):
    sys.exit(0)

def _sum(field):
    vals = [r.get(field) for r in sub_records if isinstance(r.get(field), (int, float))]
    return sum(vals) if vals else None

total_input  = _sum("input_tokens")
total_output = _sum("output_tokens")
cache_read   = _sum("cache_read_tokens") or 0
cache_create = _sum("cache_creation_tokens") or 0
total_in_for_rate = total_input or 0
cache_rate = None
if total_in_for_rate:
    cache_rate = round(cache_read / total_in_for_rate, 3)

duration_ms = _sum("duration_ms")

qa = (state or {}).get("qa_verdicts") or []
qa_pass = sum(1 for v in qa if v == "pass")
qa_pass_rate = round(qa_pass / len(qa), 3) if qa else None

# task_class is best-effort: look at which agents fired.
agents = {r.get("agent") for r in sub_records if r.get("agent")}
if {"frontend-engineer", "backend-engineer", "test-engineer"} & agents:
    task_class = "implement"
elif "planner" in agents:
    task_class = "plan"
elif "researcher" in agents:
    task_class = "research"
elif "retrospective" in agents:
    task_class = "fix"
elif agents:
    task_class = "other"
else:
    task_class = "question"

mistakes_recorded = 0
# Heuristic: a librarian append after a retrospective in this session is a recorded mistake.
# Without parsing librarian outputs we approximate by counting retrospective subagent runs.
mistakes_recorded = sum(1 for r in sub_records if r.get("agent") == "retrospective" and not r.get("blocked"))

summary = {
    "kind": "session",
    "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
    "session_id": session_id,
    "project_root": project_root,
    "task_class": task_class,
    "subagent_count": len(sub_records),
    "total_input_tokens": total_input,
    "total_output_tokens": total_output,
    "cache_hit_rate": cache_rate,
    "duration_ms": duration_ms,
    "auditor_verdict": (state or {}).get("auditor_verdict"),
    "qa_pass_rate": qa_pass_rate,
    "retro_triggered": bool((state or {}).get("retro_needed") is False and ((state or {}).get("retro_prompts"))) or bool((state or {}).get("retro_needed")),
    "mistakes_recorded": mistakes_recorded,
}

try:
    with jsonl.open("a") as f:
        f.write(json.dumps(summary) + "\n")
except OSError:
    pass
PY

exit 0
