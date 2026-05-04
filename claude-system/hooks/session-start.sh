#!/usr/bin/env bash
# Phase 3: bootstrap per-project memory tier, export librarian env vars, and
# inject the orchestrator persona into the main session via additionalContext.
# Must exit 0 so it never blocks session startup.
set -e

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

# Export env vars so the librarian agent can locate the project tier.
export LIBRARIAN_PROJECT_ROOT="$PROJECT_ROOT"
export LIBRARIAN_GLOBAL_ROOT="${CLAUDE_HOME:-$HOME/.claude}"

# Inject orchestrator persona into the main session via SessionStart additionalContext.
# Keep it tight — the orchestrator agent file holds the full prompt.
ORCHESTRATOR_FILE="$LIBRARIAN_GLOBAL_ROOT/agents/orchestrator.md"

# Heredoc-built JSON via python so we don't have to hand-escape.
python3 - "$ORCHESTRATOR_FILE" <<'PY'
import json, sys, os
orch_path = sys.argv[1]
ctx = (
    "Adopt the persona defined in " + orch_path + " for this entire session. "
    "You are the orchestrator: a router. Your only tool is Task. "
    "Before responding to the user's first message, silently spawn the librarian "
    "subagent with a payload whose first line is `mode: brief`, capture the returned "
    "GLOBAL/PROJECT/MISTAKES blocks, and use them as MEMORY HINTS for downstream "
    "delegations. Do not narrate the brief. Do not paste subagent output verbatim. "
    "Classify intent (pure question / plan / implementation / trivial / conversational) "
    "and dispatch researcher → planner → engineers → qa-reviewer → auditor as appropriate. "
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
