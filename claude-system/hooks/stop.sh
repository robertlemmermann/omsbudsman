#!/usr/bin/env bash
# Phase 4: enforce the auditor gate.
#
# Read JSON from stdin (Claude Code Stop-hook contract). Look up the
# session-state file the orchestrator writes at each gate. If any QA
# verdicts were recorded but auditor_verdict is null, emit a JSON
# "decision: block" message so the orchestrator must run the auditor.
#
# Bypass: set CLAUDE_SKIP_AUDIT=1 in the environment for the rare case
# the user is mid-work and wants to stop without auditing.
#
# Phases 5 and 6 will extend this hook for retrospective + telemetry.
set -e

if [ "${CLAUDE_SKIP_AUDIT:-0}" = "1" ]; then
  exit 0
fi

INPUT="$(cat 2>/dev/null || true)"
[ -z "$INPUT" ] && exit 0

if ! command -v python3 >/dev/null 2>&1; then
  exit 0
fi

GLOBAL_ROOT="${LIBRARIAN_GLOBAL_ROOT:-${CLAUDE_HOME:-$HOME/.claude}}"
STATE_DIR="$GLOBAL_ROOT/state"

python3 - "$STATE_DIR" "$INPUT" <<'PY'
import json, sys, pathlib

state_dir = sys.argv[1]
raw = sys.argv[2]

try:
    payload = json.loads(raw)
except json.JSONDecodeError:
    sys.exit(0)

if payload.get("stop_hook_active"):
    sys.exit(0)

session_id = payload.get("session_id")
if not session_id:
    sys.exit(0)

state_path = pathlib.Path(state_dir) / f"session-{session_id}.json"
if not state_path.is_file():
    sys.exit(0)

try:
    state = json.loads(state_path.read_text())
except (OSError, json.JSONDecodeError):
    sys.exit(0)

qa_verdicts = state.get("qa_verdicts") or []
auditor_verdict = state.get("auditor_verdict")

if qa_verdicts and auditor_verdict is None:
    out = {
        "decision": "block",
        "reason": (
            "auditor not run — run the auditor agent against the original user "
            "request, the PLAN, all engineer CHANGES, and the QA verdicts before "
            "responding. Set CLAUDE_SKIP_AUDIT=1 to bypass for this stop only."
        ),
    }
    print(json.dumps(out))
PY

exit 0
