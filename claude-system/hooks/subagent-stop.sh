#!/usr/bin/env bash
# Phase 6: per-subagent telemetry. Append one JSONL record per Task return
# to ~/.claude/metrics/sessions.jsonl. Must exit 0 fast — never blocks.
#
# Opt out by setting CLAUDE_MULTIAGENT_NO_METRICS=1.
set -e

if [ "${CLAUDE_MULTIAGENT_NO_METRICS:-0}" = "1" ]; then
  exit 0
fi

INPUT="$(cat 2>/dev/null || true)"
[ -z "$INPUT" ] && exit 0

if ! command -v python3 >/dev/null 2>&1; then
  exit 0
fi

GLOBAL_ROOT="${LIBRARIAN_GLOBAL_ROOT:-${CLAUDE_HOME:-$HOME/.claude}}"
PROJECT_ROOT="${LIBRARIAN_PROJECT_ROOT:-$(pwd)}"
METRICS_DIR="$GLOBAL_ROOT/metrics"
STATE_DIR="$GLOBAL_ROOT/state"
mkdir -p "$METRICS_DIR" "$STATE_DIR" 2>/dev/null || true

JSONL="$METRICS_DIR/sessions.jsonl"

python3 - "$JSONL" "$PROJECT_ROOT" "$STATE_DIR" "$INPUT" <<'PY'
import json, sys, datetime, pathlib

jsonl_path = pathlib.Path(sys.argv[1])
project_root = sys.argv[2]
state_dir = pathlib.Path(sys.argv[3])
raw = sys.argv[4]

try:
    payload = json.loads(raw)
except json.JSONDecodeError:
    sys.exit(0)

# Claude Code's SubagentStop payload shape can vary across versions; tolerate
# missing fields. The schema we record is stable regardless.
def get(obj, *path, default=None):
    cur = obj
    for k in path:
        if not isinstance(cur, dict) or k not in cur:
            return default
        cur = cur[k]
    return cur

usage = get(payload, "usage") or get(payload, "subagent", "usage") or {}

record = {
    "schema_version": "1.0",
    "kind": "subagent",
    "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
    "session_id": payload.get("session_id"),
    "project_root": project_root,
    "claude_code_version": payload.get("claude_code_version") or get(payload, "version") or None,
    "agent": (
        get(payload, "subagent_type")
        or get(payload, "subagent", "type")
        or get(payload, "agent")
    ),
    "model": get(payload, "model") or get(payload, "subagent", "model"),
    "input_tokens": usage.get("input_tokens"),
    "output_tokens": usage.get("output_tokens"),
    "cache_read_tokens": usage.get("cache_read_input_tokens") or usage.get("cache_read_tokens"),
    "cache_creation_tokens": usage.get("cache_creation_input_tokens") or usage.get("cache_creation_tokens"),
    "duration_ms": payload.get("duration_ms") or get(payload, "subagent", "duration_ms"),
    "blocked": bool(payload.get("blocked")),
    "outcome": payload.get("outcome") or ("blocked" if payload.get("blocked") else "ok"),
}

# Rotate by size (>10 MB) OR by month boundary, whichever comes first.
# Keep the last 4 size-rotation archives; monthly archives are kept indefinitely
# under their year-month slug so users can ask "show me April".
try:
    if jsonl_path.is_file():
        import gzip, shutil, glob, os
        size = jsonl_path.stat().st_size
        now = datetime.datetime.now(datetime.timezone.utc)
        # Detect month rollover: read first line's ts; if its month differs
        # from the current month, archive the file under its year-month slug.
        first_month = None
        if size > 0:
            try:
                with jsonl_path.open() as f:
                    line = f.readline().strip()
                if line:
                    obj = json.loads(line)
                    ts = obj.get("ts") or ""
                    if len(ts) >= 7:
                        first_month = ts[:7]  # "YYYY-MM"
            except (OSError, json.JSONDecodeError, ValueError):
                first_month = None
        cur_month = now.strftime("%Y-%m")
        rotate_size  = size > 10 * 1024 * 1024
        rotate_month = first_month is not None and first_month != cur_month
        if rotate_size or rotate_month:
            tag = first_month if rotate_month else now.strftime("%Y%m%d-%H%M%S")
            archive = jsonl_path.parent / f"sessions.{tag}.jsonl.gz"
            with jsonl_path.open("rb") as src, gzip.open(archive, "wb") as dst:
                shutil.copyfileobj(src, dst)
            jsonl_path.write_text("")
            # Only the size-rotation pattern gets pruned; monthly-tagged
            # archives (tag form "YYYY-MM", length 7) stay forever.
            all_archives = sorted(glob.glob(str(jsonl_path.parent / "sessions.*.jsonl.gz")))
            ts_archives = []
            for a in all_archives:
                stem_parts = pathlib.Path(a).name.split(".")
                if len(stem_parts) >= 2 and len(stem_parts[1]) != 7:
                    ts_archives.append(a)
            for old in ts_archives[:-4]:
                try: os.remove(old)
                except OSError: pass
except OSError:
    pass

try:
    with jsonl_path.open("a") as f:
        f.write(json.dumps(record) + "\n")
except OSError:
    pass

# --- Team activity state update (for statusLine renderer) ---
session_id = payload.get("session_id")
agent_name = record["agent"]
if session_id and agent_name:
    state_path = state_dir / f"agents-{session_id}.json"
    if state_path.is_file():
        try:
            astate = json.loads(state_path.read_text())
        except (OSError, json.JSONDecodeError):
            astate = None
        if isinstance(astate, dict) and isinstance(astate.get("agents"), list):
            # Pull a one-line summary from the agent's response, if present.
            response = (
                payload.get("response")
                or get(payload, "subagent", "response")
                or get(payload, "result")
                or ""
            )
            if isinstance(response, dict):
                response = response.get("content") or response.get("text") or ""
            if isinstance(response, list):
                # Join text-blocks if the harness gives us a content array.
                pieces = []
                for blk in response:
                    if isinstance(blk, dict):
                        pieces.append(blk.get("text") or "")
                response = "\n".join(p for p in pieces if p)
            if not isinstance(response, str):
                response = str(response)

            summary_line = ""
            for line in response.splitlines():
                s = line.strip()
                if s and not s.startswith(("```", "---", "===")):
                    summary_line = s
                    break
            if len(summary_line) > 100:
                summary_line = summary_line[:99].rstrip() + "…"

            # Verdict normalization for gate agents.
            outcome = "blocked" if record["blocked"] else "ok"
            low_resp = response.lower()
            if agent_name == "qa-reviewer":
                if "verdict: pass" in low_resp or "\npass" in low_resp[:200]:
                    outcome = "pass"
                elif "verdict: fail" in low_resp or "\nfail" in low_resp[:200]:
                    outcome = "fail"
            elif agent_name == "auditor":
                for v in ("approve", "revise", "escalate"):
                    if f"verdict: {v}" in low_resp or v in low_resp[:120]:
                        outcome = v
                        break

            status = "blocked" if record["blocked"] else (
                "failed" if outcome in ("fail",) else "done"
            )

            # Mark the most recent matching active entry as finished.
            for entry in reversed(astate["agents"]):
                if entry.get("agent") == agent_name and entry.get("status") == "active":
                    entry["status"] = status
                    entry["ended_at"] = record["ts"]
                    entry["summary"] = summary_line or None
                    entry["outcome"] = outcome
                    break
            else:
                # No matching active entry (e.g., PreToolUse hook missed); append a synthetic one.
                astate["agents"].append({
                    "agent": agent_name,
                    "description": "",
                    "status": status,
                    "started_at": record["ts"],
                    "ended_at": record["ts"],
                    "summary": summary_line or None,
                    "outcome": outcome,
                })
                astate["agents"] = astate["agents"][-30:]

            astate["updated_at"] = record["ts"]
            try:
                state_path.write_text(json.dumps(astate, indent=2) + "\n")
            except OSError:
                pass
PY

exit 0
