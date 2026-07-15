"""PreToolUse hook (matcher: Task): record each subagent dispatch into a
per-session team-activity file so tooling can show which agent is working.

Never blocks tool execution; never prints to stdout.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _common

META_PREFIXES = ("context:", "memory hints:", "deliverable:", "cap:", "mode:")


def summarize(tool_input):
    desc = (tool_input.get("description") or "").strip()
    if desc:
        summary = desc
    else:
        summary = ""
        for line in (tool_input.get("prompt") or "").splitlines():
            s = line.strip()
            if not s:
                continue
            low = s.lower()
            if low.startswith("task:"):
                summary = s.split(":", 1)[1].strip()
                break
            if not low.startswith(META_PREFIXES):
                summary = s
                break
    if len(summary) > 100:
        summary = summary[:99].rstrip() + "…"
    return summary


def body(payload):
    if payload.get("tool_name") not in ("Task", "Agent"):
        return
    session_id = str(payload.get("session_id") or "").strip()
    if not session_id:
        return

    tool_input = payload.get("tool_input") or {}
    if not isinstance(tool_input, dict):
        tool_input = {}
    agent = tool_input.get("subagent_type") or "unknown"

    root = _common.project_root()
    state_path = _common.state_dir(root) / ("agents-" + session_id + ".json")
    state = _common.read_json(state_path)
    if not isinstance(state, dict) or not isinstance(state.get("agents"), list):
        state = {"session_id": session_id, "agents": []}

    now = _common.utc_now()
    state["agents"].append({
        "agent": agent,
        "description": summarize(tool_input),
        "status": "active",
        "started_at": now,
        "ended_at": None,
        "outcome": None,
    })
    state["agents"] = state["agents"][-30:]
    state["session_id"] = session_id
    state["updated_at"] = now
    _common.atomic_write_json(state_path, state)


if __name__ == "__main__":
    _common.run(body)
