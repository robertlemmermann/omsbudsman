#!/usr/bin/env bash
# Uninstaller — removes our agents/hooks/settings entries, preserves memory.
# Always backs up the current state before changing anything.
set -euo pipefail

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$SCRIPT_DIR/claude-system"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
PREUNINSTALL_DIR="$HOME/.claude.preuninstall-$TIMESTAMP"

if [ ! -d "$CLAUDE_HOME" ]; then
  echo "Nothing to uninstall — $CLAUDE_HOME does not exist."
  exit 0
fi

if [ ! -d "$SOURCE_DIR" ]; then
  echo "ERROR: source directory not found: $SOURCE_DIR" >&2
  echo "Run from the repository root." >&2
  exit 1
fi

echo "Backing up current state to $PREUNINSTALL_DIR"
cp -R "$CLAUDE_HOME" "$PREUNINSTALL_DIR"

echo "Removing our agents..."
for agent_file in "$SOURCE_DIR/agents/"*.md; do
  name=$(basename "$agent_file")
  rm -f "$CLAUDE_HOME/agents/$name"
done

echo "Removing our hooks..."
for hook_file in "$SOURCE_DIR/hooks/"*; do
  name=$(basename "$hook_file")
  rm -f "$CLAUDE_HOME/hooks/$name"
done

SETTINGS="$CLAUDE_HOME/settings.json"
if [ -f "$SETTINGS" ] && command -v python3 >/dev/null 2>&1; then
  echo "Cleaning settings entries..."
  HOOKS_DIR="$CLAUDE_HOME/hooks"
  python3 - "$SETTINGS" "$HOOKS_DIR" <<'PY'
import json, os, sys
settings_path, hooks_dir = sys.argv[1], sys.argv[2]

with open(settings_path) as f:
    settings = json.load(f)

def is_ours(entry):
    cmd = entry.get("command", "")
    return hooks_dir in cmd

hooks = settings.get("hooks", {})
for event, groups in list(hooks.items()):
    if not isinstance(groups, list):
        continue
    new_groups = []
    for g in groups:
        inner = g.get("hooks", []) if isinstance(g, dict) else []
        kept = [h for h in inner if not is_ours(h)]
        if kept:
            g["hooks"] = kept
            new_groups.append(g)
    if new_groups:
        hooks[event] = new_groups
    else:
        del hooks[event]

if not hooks:
    settings.pop("hooks", None)
else:
    settings["hooks"] = hooks

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
PY
fi

echo "Memory preserved at $CLAUDE_HOME/memory/"
echo
echo "Uninstall complete."
echo "  Backup: $PREUNINSTALL_DIR"
