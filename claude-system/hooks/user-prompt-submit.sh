#!/usr/bin/env bash
# Phase 5: detect correction signals in the user's prompt and set
# retro_needed=true on the session-state file. Broad regex on purpose —
# the retrospective agent is the second filter that drops false positives.
#
# Always exits 0 — this hook NEVER blocks the user's prompt.
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
import json, sys, re, pathlib

state_dir = pathlib.Path(sys.argv[1])
raw = sys.argv[2]

try:
    payload = json.loads(raw)
except json.JSONDecodeError:
    sys.exit(0)

session_id = payload.get("session_id")
prompt = payload.get("prompt") or ""
if not session_id or not prompt.strip():
    sys.exit(0)

# Broad correction-signal patterns. False positives are acceptable;
# the retrospective agent filters them in step 1.
PATTERNS = [
    r"\b(no|nope|wrong|incorrect|broken|fail(ed|ing)?|bug)\b",
    r"\b(actually|instead|rather|but)\b.*\b(should|shouldn'?t|need(s|ed)?)\b",
    r"\b(you|claude|the agent)\b.*\b(missed|forgot|didn'?t|should have|were supposed)\b",
    r"\b(fix|revert|undo|rollback|redo)\b",
    r"\b(why|how come)\b.*\b(did|didn'?t)\b",
    r"\b(retrospective|post-?mortem|learn from this)\b",
]

text = prompt.lower()
hit = None
for pat in PATTERNS:
    if re.search(pat, text, re.IGNORECASE | re.DOTALL):
        hit = pat
        break

if not hit:
    sys.exit(0)

state_path = state_dir / f"session-{session_id}.json"
state = {}
if state_path.is_file():
    try:
        state = json.loads(state_path.read_text())
    except (OSError, json.JSONDecodeError):
        state = {}

state.setdefault("session_id", session_id)
state.setdefault("qa_verdicts", [])
state.setdefault("auditor_verdict", None)
state["retro_needed"] = True
prompts = state.get("retro_prompts") or []
# Cap at 5 retained prompts to keep the file small.
prompts = (prompts + [prompt.strip()])[-5:]
state["retro_prompts"] = prompts

try:
    state_path.write_text(json.dumps(state, indent=2) + "\n")
except OSError:
    pass

# Stay silent on stdout — never pollute the user-facing transcript.
PY

exit 0
