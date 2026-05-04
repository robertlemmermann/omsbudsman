#!/usr/bin/env bash
# Phase 2: bootstrap per-project memory tier and signal librarian to load brief.
# The orchestrator (phase 3) actually invokes the librarian; this hook only
# prepares the filesystem and exports env vars the agent reads.
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

echo "[claude-multi-agent] memory tiers ready: $LIBRARIAN_GLOBAL_ROOT/memory + $PROJECT_MEMORY_DIR" >&2
exit 0
