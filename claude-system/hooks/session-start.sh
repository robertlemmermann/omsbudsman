#!/usr/bin/env bash
# Phase 4: bootstrap per-project memory tier, export librarian env vars,
# bake session id + state path into the orchestrator persona via
# additionalContext, and inject the orchestrator persona itself.
# Must exit 0 so it never blocks session startup.
set -e

# Read SessionStart payload (Claude Code passes session_id, transcript_path,
# cwd, etc. as JSON on stdin). Tolerate empty stdin in test harnesses.
HOOK_INPUT="$(cat 2>/dev/null || true)"

# Locate project root: git toplevel, fall back to cwd.
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

PROJECT_MEMORY_DIR="$PROJECT_ROOT/.claude/memory"
mkdir -p "$PROJECT_MEMORY_DIR/mistakes" 2>/dev/null || true

# Seed a project-tier INDEX.md if missing — librarian creates the rest lazily.
if [ ! -f "$PROJECT_MEMORY_DIR/INDEX.md" ]; then
  cat > "$PROJECT_MEMORY_DIR/INDEX.md" <<'EOF'
# Memory Index — Project

> Last updated: (none) · Entries: 0

Project-tier memory. Maintained by the librarian agent.

## Layout

- `project.md` — stack, conventions, gotchas, architecture notes
- `decisions.md` — project-specific decisions with rationale
- `mistakes/INDEX.md` — tag → file map for prevention rules
- `mistakes/<topic>.md` — prevention rules for this codebase
EOF
fi

if [ ! -f "$PROJECT_MEMORY_DIR/mistakes/INDEX.md" ]; then
  cat > "$PROJECT_MEMORY_DIR/mistakes/INDEX.md" <<'EOF'
# Mistakes Index — Project

> Last updated: (none) · Entries: 0

Tag → file map for project-specific prevention rules.
EOF
fi

# Export env vars so subagents can locate the project tier and state dir.
export LIBRARIAN_PROJECT_ROOT="$PROJECT_ROOT"
export LIBRARIAN_GLOBAL_ROOT="${CLAUDE_HOME:-$HOME/.claude}"

STATE_DIR="$LIBRARIAN_GLOBAL_ROOT/state"
mkdir -p "$STATE_DIR" 2>/dev/null || true

ORCHESTRATOR_FILE="$LIBRARIAN_GLOBAL_ROOT/agents/orchestrator.md"

# Build additionalContext via python — extracts session_id from stdin payload
# and embeds the resolved state-file path so the orchestrator persona can
# write its gate-state JSON at exactly that path.
python3 - "$ORCHESTRATOR_FILE" "$STATE_DIR" "$HOOK_INPUT" <<'PY'
import json, sys

orch_path, state_dir, raw = sys.argv[1], sys.argv[2], sys.argv[3]

session_id = ""
try:
    session_id = (json.loads(raw).get("session_id") or "") if raw else ""
except json.JSONDecodeError:
    session_id = ""

if session_id:
    state_path = state_dir + "/session-" + session_id + ".json"
    state_clause = (
        "Your gate-state file is " + state_path + ". Initialize it with "
        '{"session_id": "' + session_id + '", "qa_verdicts": [], "auditor_verdict": null, "retro_needed": false} '
        "before the first QA dispatch. Append each QA verdict (pass/fail) to qa_verdicts as it returns. "
        "Set auditor_verdict to the auditor's approve/revise/escalate string immediately after the auditor runs. "
        "The Stop hook reads this file and refuses clean termination if qa_verdicts is non-empty and auditor_verdict is null."
    )
else:
    state_clause = (
        "Session id was not provided by the harness; gate-state recording is disabled this session. "
        "Run all gates manually and do not rely on the Stop hook to flag a missed audit."
    )

ctx = (
    "Adopt the persona defined in " + orch_path + " for this entire session. "
    "You are the orchestrator: a router. "
    "Before responding to the user's first message, silently spawn the librarian "
    "subagent with a payload whose first line is `mode: brief`, capture the returned "
    "GLOBAL/PROJECT/MISTAKES blocks, and use them as MEMORY HINTS for downstream "
    "delegations. Do not narrate the brief. Do not paste subagent output verbatim. "
    "Classify intent (pure question / plan / implementation / trivial / conversational) "
    "and dispatch researcher → planner → engineers (frontend/backend/test) → qa-reviewer → "
    "auditor as appropriate. Use Bash only to maintain the gate-state file described next; "
    "use no other file/shell tools yourself. " + state_clause + " "
    "Read " + orch_path + " now if you have not already."
)

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": ctx,
    }
}))
PY

echo "[claude-multi-agent] memory tiers ready: $LIBRARIAN_GLOBAL_ROOT/memory + $PROJECT_MEMORY_DIR" >&2
exit 0
