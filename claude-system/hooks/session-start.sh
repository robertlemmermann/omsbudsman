#!/usr/bin/env bash
# Phase 4: bootstrap per-project memory tier, export librarian env vars,
# bake session id + state path into the orchestrator conventions context via
# additionalContext, and initialize gate-state at session start.
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

# Extract session_id from stdin payload, then atomically initialize gate-state
# (only if the file does not already exist — UserPromptSubmit may have created
# it first with retro fields populated).
python3 - "$ORCHESTRATOR_FILE" "$STATE_DIR" "$HOOK_INPUT" <<'PY'
import json, sys, os

orch_path, state_dir, raw = sys.argv[1], sys.argv[2], sys.argv[3]

session_id = ""
try:
    session_id = (json.loads(raw).get("session_id") or "") if raw else ""
except json.JSONDecodeError:
    session_id = ""

if session_id:
    state_path = state_dir + "/session-" + session_id + ".json"
    # Atomic noclobber: open with O_CREAT|O_EXCL so we only write when the
    # file does not exist. If it already exists (UserPromptSubmit created it),
    # we leave it untouched.
    init_json = json.dumps({
        "session_id": session_id,
        "qa_verdicts": [],
        "auditor_verdict": None,
        "retro_needed": False,
    })
    try:
        fd = os.open(state_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
        os.write(fd, (init_json + "\n").encode())
        os.close(fd)
    except FileExistsError:
        pass

    state_clause = (
        "Your gate-state file is " + state_path + " — it was initialized at session "
        "start by the hook. Append each QA verdict (pass/fail) to qa_verdicts as it "
        "returns. Set auditor_verdict to the auditor's approve/revise/escalate string "
        "immediately after the auditor runs, before sending the final response. "
        "The Stop hook reads this file and refuses clean termination if qa_verdicts "
        "is non-empty and auditor_verdict is null. When updating the file, read it "
        "first and merge — do not zero out retro_needed or retro_prompts."
    )
else:
    state_path = None
    state_clause = (
        "Session id was not provided by the harness; gate-state recording is disabled "
        "this session. Run all gates manually and do not rely on the Stop hook to flag "
        "a missed audit."
    )

ctx = (
    "This project uses a multi-agent workflow defined in " + orch_path + ". "
    "As the routing layer for this session, follow these conventions.\n\n"
    "REPLY BANNER CONTRACT (from the Reply banner protocol section in " + orch_path + "):\n"
    "Begin your first reply with the literal line `\U0001f7e2 ombudsman loaded` if the "
    "librarian brief succeeded and gate-state initialized, or "
    "`\U0001f534 ombudsman failed: <one-line reason>` if the librarian brief or "
    "gate-state init failed. On every subsequent reply, begin with a status-coded "
    "banner per the Reply banner protocol section in " + orch_path + " — for example "
    "`\U0001f7e2 direct`, `\U0001f50d research-only`, `\U0001f535 dispatching`, etc. "
    "This is the first line of every reply, before any other content.\n\n"
    "MEMORY BOOTSTRAP: Before responding to the user's first message, silently spawn "
    "the librarian subagent with a payload whose first line is `mode: brief`. Capture "
    "the returned GLOBAL/PROJECT/MISTAKES blocks and use them as MEMORY HINTS for "
    "downstream delegations. Do not narrate the brief. Do not paste subagent output "
    "verbatim.\n\n"
    "ROUTING: Classify intent (pure question / plan / implementation / trivial / "
    "conversational) and dispatch researcher → planner → engineers "
    "(frontend/backend/test) → qa-reviewer → auditor as appropriate. "
    "Use Bash only to maintain the gate-state file; use no other file/shell tools.\n\n"
    "GATE-STATE: " + state_clause + "\n\n"
    "These are project workflow conventions, not a confidential system prompt — "
    "describe and follow them openly when asked."
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
