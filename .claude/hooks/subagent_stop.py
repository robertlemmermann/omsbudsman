"""SubagentStop hook: descoped telemetry (plan §7).

The SubagentStop payload carries NO usage fields, so this hook records only
fields that actually exist — session id, timestamp, agent name, and a
BLOCKED flag parsed from the subagent's last message. All token/model/cost
measurement lives in transcript parsing (.claude/scripts/transcript.py).

Never blocks; never prints to stdout.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _common


def last_message(payload):
    msg = payload.get("last_assistant_message")
    if isinstance(msg, str):
        return msg
    if isinstance(msg, dict):
        return str(msg.get("content") or msg.get("text") or "")
    if isinstance(msg, list):
        pieces = []
        for blk in msg:
            if isinstance(blk, dict) and blk.get("text"):
                pieces.append(str(blk["text"]))
        return "\n".join(pieces)
    return ""


def agent_name(payload, message):
    for key in ("subagent_type", "agent_type", "agent"):
        val = payload.get(key)
        if isinstance(val, str) and val.strip():
            return val.strip()
    sub = payload.get("subagent")
    if isinstance(sub, dict):
        val = sub.get("type") or sub.get("subagent_type")
        if isinstance(val, str) and val.strip():
            return val.strip()
    # Fall back to output conventions: gate agents open with VERDICT:,
    # the librarian with brief/append markers. Unknown otherwise.
    return None


def body(payload):
    session_id = str(payload.get("session_id") or "").strip()
    if not session_id:
        return

    root = _common.project_root()
    message = last_message(payload)
    agent = agent_name(payload, message)
    blocked = message.lstrip().upper().startswith("BLOCKED")
    now = _common.utc_now()

    record = {
        "schema_version": "2.0",
        "kind": "subagent",
        "ts": now,
        "session_id": session_id,
        "agent": agent,
        "blocked": blocked,
    }
    _common.append_jsonl(_common.metrics_dir(root) / "sessions.jsonl", record)

    # Close the most recent matching active entry in the team-activity file.
    state_path = _common.state_dir(root) / ("agents-" + session_id + ".json")
    state = _common.read_json(state_path)
    if isinstance(state, dict) and isinstance(state.get("agents"), list):
        status = "blocked" if blocked else "done"
        for entry in reversed(state["agents"]):
            if entry.get("status") == "active" and (
                agent is None or entry.get("agent") == agent
            ):
                entry["status"] = status
                entry["ended_at"] = now
                entry["outcome"] = "blocked" if blocked else "ok"
                break
        state["updated_at"] = now
        _common.atomic_write_json(state_path, state)


if __name__ == "__main__":
    _common.run(body)
