#!/usr/bin/env bash
# Project SessionStart hook for Claude Code on the web.
#
# Installs the multi-agent system into ~/.claude/ inside the remote
# sandbox so the orchestrator, librarian, and memory tiers are live for
# the first turn. Idempotent — install.sh handles re-runs safely.
#
# No-op outside Claude Code on the web (local sessions should run
# install.sh themselves once, not on every session start).
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"

# Pass the SessionStart payload through to the system hook below.
HOOK_INPUT="$(cat 2>/dev/null || true)"

# Skip the install step if the system is already in place (warm sandbox cache).
if [ ! -f "$CLAUDE_HOME/agents/orchestrator.md" ]; then
  (cd "$PROJECT_DIR" && ./install.sh) >&2
fi

# Run the freshly installed SessionStart hook for *this* session so the
# orchestrator persona and memory tiers are wired up without requiring a
# session restart. Its JSON stdout becomes our hookSpecificOutput.
SYS_HOOK="$CLAUDE_HOME/hooks/session-start.sh"
if [ -x "$SYS_HOOK" ]; then
  printf '%s' "$HOOK_INPUT" | "$SYS_HOOK"
fi
