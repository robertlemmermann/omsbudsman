#!/usr/bin/env bash
# Phase 7: capture Task tool dispatches into a per-session "team activity" state
# file so the statusLine renderer can show which agent is currently working.
#
# Always exits 0 — never blocks tool execution.
set -e

INPUT="$(cat 2>/dev/null || true)"
[ -z "$INPUT" ] && exit 0

if ! command -v python3 >/dev/null 2>&1; then
  exit 0
fi

GLOBAL_ROOT="${LIBRARIAN_GLOBAL_ROOT:-${CLAUDE_HOME:-$HOME/.claude}}"
STATE_DIR="$GLOBAL_ROOT/state"
mkdir -p "$STATE_DIR" 2>/dev/null || true

python3 - "$STATE_DIR" "$INPUT" <<'PY'
import json, sys, datetime, pathlib

state_dir = pathlib.Path(sys.argv[1])
raw = sys.argv[2]

try:
    payload = json.loads(raw)
except json.JSONDecodeError:
    sys.exit(0)

if payload.get("tool_name") != "Task":
    sys.exit(0)

session_id = payload.get("session_id")
if not session_id:
    sys.exit(0)

ti = payload.get("tool_input") or {}
agent = ti.get("subagent_type") or "unknown"
desc = (ti.get("description") or "").strip()
prompt = ti.get("prompt") or ""

# Prefer the explicit description; fall back to the orchestrator's
# `TASK: <one-sentence goal>` line; finally use the first non-meta line.
summary = desc
if not summary:
    for line in prompt.splitlines():
        s = line.strip()
        if not s:
            continue
        low = s.lower()
        if low.startswith("task:"):
            summary = s.split(":", 1)[1].strip()
            break
        if not low.startswith(("context:", "memory hints:", "deliverable:", "cap:", "mode:")):
            summary = s
            break
if len(summary) > 100:
    summary = summary[:99].rstrip() + "…"

state_path = state_dir / f"agents-{session_id}.json"
state = {"session_id": session_id, "agents": []}
if state_path.is_file():
    try:
        loaded = json.loads(state_path.read_text())
        if isinstance(loaded, dict):
            state = loaded
            state.setdefault("agents", [])
    except (OSError, json.JSONDecodeError):
        pass

now = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
state["agents"].append({
    "agent": agent,
    "description": summary,
    "status": "active",
    "started_at": now,
    "ended_at": None,
    "summary": None,
    "outcome": None,
})
# Keep the last 30 entries; older ones aren't useful for a live status line.
state["agents"] = state["agents"][-30:]
state["session_id"] = session_id
state["updated_at"] = now

try:
    state_path.write_text(json.dumps(state, indent=2) + "\n")
except OSError:
    pass
PY

exit 0
