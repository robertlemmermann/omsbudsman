"""UserPromptSubmit hook: detect correction signals in the user's prompt and
flip retro_needed=true on the session gate-state file.

Deliberately trigger-happy — the retrospective agent is the second filter
that drops false positives. Never blocks the prompt; never prints to stdout.
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _common

PATTERNS = [
    r"\b(no|nope|wrong|incorrect|broken|fail(ed|ing)?|bug)\b",
    r"\b(actually|instead|rather|but)\b.*\b(should|shouldn'?t|need(s|ed)?)\b",
    r"\b(you|claude|the agent)\b.*\b(missed|forgot|didn'?t|should have|were supposed)\b",
    r"\b(fix|revert|undo|rollback|redo)\b",
    r"\b(why|how come)\b.*\b(did|didn'?t)\b",
    r"\b(retrospective|post-?mortem|learn from this)\b",
]


def detect(prompt):
    text = prompt.lower()
    for pat in PATTERNS:
        if re.search(pat, text, re.IGNORECASE | re.DOTALL):
            return True
    return False


def body(payload):
    session_id = str(payload.get("session_id") or "").strip()
    prompt = payload.get("prompt") or ""
    if not session_id or not prompt.strip() or not detect(prompt):
        return

    root = _common.project_root()
    state_path = _common.state_dir(root) / ("session-" + session_id + ".json")
    state = _common.read_json(state_path) or {}
    if not isinstance(state, dict):
        state = {}
    state.setdefault("session_id", session_id)
    state.setdefault("qa_verdicts", [])
    state.setdefault("auditor_verdict", None)
    state["retro_needed"] = True
    prompts = state.get("retro_prompts") or []
    state["retro_prompts"] = (prompts + [prompt.strip()])[-5:]
    _common.atomic_write_json(state_path, state)


if __name__ == "__main__":
    _common.run(body)
