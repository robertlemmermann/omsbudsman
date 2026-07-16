"""Stop hook: enforce the auditor + retrospective gates, flag runaway-cost
sessions, and append a per-session telemetry summary.

Blocks clean termination when:
  (a) qa_verdicts is non-empty AND auditor_verdict is null AND a diff was
      produced  -> the auditor gate was skipped
  (b) retro_needed is true                       -> retrospective is pending

Bypass for one stop only: CLAUDE_SKIP_AUDIT=1 (documented in README).
Telemetry opt-out: CLAUDE_OMBUDSMAN_NO_METRICS=1.
"""
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _common


def gate_reasons(state):
    reasons = []
    qa_verdicts = state.get("qa_verdicts") or []
    auditor_verdict = state.get("auditor_verdict")
    diff_produced = state.get("diff_produced")
    if diff_produced is None:
        diff_produced = True
    if qa_verdicts and auditor_verdict is None and diff_produced:
        reasons.append(
            "auditor not run — run the auditor agent against the original user "
            "request, the PLAN, all engineer CHANGES, and the QA verdicts before "
            "responding."
        )
    if state.get("retro_needed"):
        reasons.append(
            "corrections happened this session — run the retrospective agent, "
            "then dispatch librarian (mode: append) with its payload, or clear "
            "retro_needed via state.py if the retrospective calls it a false positive."
        )
    return reasons


def circuit_breaker_note(root, session_id, state):
    """Flag sessions whose subagent count exceeds 3x the class baseline.

    Baseline lives at .ombudsman/metrics/baseline.json:
      {"classes": {"implement": {"median_subagents": 6}, ...}}
    Silent when no baseline exists (pre-P8 surfaces).
    """
    baseline = _common.read_json(_common.metrics_dir(root) / "baseline.json")
    if not isinstance(baseline, dict):
        return None
    task_class = state.get("task_class") or "other"
    cls = (baseline.get("classes") or {}).get(task_class)
    if not isinstance(cls, dict):
        return None
    median = cls.get("median_subagents")
    if not isinstance(median, (int, float)) or median <= 0:
        return None
    count = count_subagents(root, session_id)
    if count > 3 * median:
        return {
            "kind": "cost_flag",
            "ts": _common.utc_now(),
            "session_id": session_id,
            "task_class": task_class,
            "subagent_count": count,
            "baseline_median": median,
        }
    return None


def count_subagents(root, session_id):
    jsonl = _common.metrics_dir(root) / "sessions.jsonl"
    count = 0
    try:
        with jsonl.open(encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if obj.get("kind") == "subagent" and obj.get("session_id") == session_id:
                    count += 1
    except OSError:
        pass
    return count


def body(payload):
    if payload.get("stop_hook_active"):
        return
    session_id = str(payload.get("session_id") or "").strip()
    if not session_id:
        return

    root = _common.project_root()
    state_path = _common.state_dir(root) / ("session-" + session_id + ".json")
    state = _common.read_json(state_path)
    if not isinstance(state, dict):
        state = None

    skip_audit = os.environ.get("CLAUDE_SKIP_AUDIT", "0") == "1"
    if state is not None and not skip_audit:
        reasons = gate_reasons(state)
        if reasons:
            print(json.dumps({
                "decision": "block",
                "reason": " | ".join(reasons)
                + " To bypass this stop only: set CLAUDE_SKIP_AUDIT=1 (use only "
                  "after verifying the work yourself).",
            }))
            return

    if os.environ.get("CLAUDE_OMBUDSMAN_NO_METRICS", "0") == "1":
        return

    sub_count = count_subagents(root, session_id)
    if state is None and sub_count == 0:
        return  # nothing happened this session; keep the log clean

    state = state or {}
    qa = state.get("qa_verdicts") or []
    qa_pass = sum(1 for v in qa if v == "pass")
    summary = {
        "schema_version": "2.0",
        "kind": "session",
        "ts": _common.utc_now(),
        "session_id": session_id,
        "task_class": state.get("task_class"),
        "subagent_count": sub_count,
        "qa_pass_rate": round(qa_pass / len(qa), 3) if qa else None,
        "auditor_verdict": state.get("auditor_verdict"),
        "retro_triggered": bool(state.get("retro_prompts")),
    }
    jsonl = _common.metrics_dir(root) / "sessions.jsonl"
    _common.append_jsonl(jsonl, summary)

    flag = circuit_breaker_note(root, session_id, state)
    if flag:
        _common.append_jsonl(jsonl, flag)
        print(
            "[ombudsman] cost flag: session used "
            + str(flag["subagent_count"]) + " subagents vs class median "
            + str(flag["baseline_median"]), file=sys.stderr,
        )


if __name__ == "__main__":
    _common.run(body)
