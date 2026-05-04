#!/usr/bin/env bash
# Installer for the Claude Code multi-agent system (macOS / Linux).
# Idempotent — re-runs are safe and create a fresh backup each time.
set -euo pipefail

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$SCRIPT_DIR/claude-system"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="$HOME/.claude.backup-$TIMESTAMP"

if [ ! -d "$SOURCE_DIR" ]; then
  echo "ERROR: source directory not found: $SOURCE_DIR" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required for the settings merge step." >&2
  exit 1
fi

if [ -d "$CLAUDE_HOME" ]; then
  echo "Backing up existing $CLAUDE_HOME -> $BACKUP_DIR"
  cp -R "$CLAUDE_HOME" "$BACKUP_DIR"
fi

mkdir -p "$CLAUDE_HOME/agents" "$CLAUDE_HOME/hooks" "$CLAUDE_HOME/memory"

echo "Installing agents..."
cp "$SOURCE_DIR/agents/"*.md "$CLAUDE_HOME/agents/"

echo "Installing hooks..."
cp "$SOURCE_DIR/hooks/"* "$CLAUDE_HOME/hooks/"
chmod +x "$CLAUDE_HOME/hooks/"*.sh

if [ ! -f "$CLAUDE_HOME/memory/INDEX.md" ]; then
  echo "Seeding memory index..."
  cp "$SOURCE_DIR/memory/INDEX.md" "$CLAUDE_HOME/memory/INDEX.md"
else
  echo "Preserving existing memory at $CLAUDE_HOME/memory/"
fi

SETTINGS="$CLAUDE_HOME/settings.json"
FRAGMENT_RAW="$SOURCE_DIR/settings.fragment.json"
FRAGMENT_RESOLVED="$(mktemp)"
trap 'rm -f "$FRAGMENT_RESOLVED"' EXIT

HOOK_CMD_SESSION_START="$CLAUDE_HOME/hooks/session-start.sh"
sed "s|{{HOOK_CMD_SESSION_START}}|$HOOK_CMD_SESSION_START|g" "$FRAGMENT_RAW" > "$FRAGMENT_RESOLVED"

echo "Merging settings..."
python3 - "$SETTINGS" "$FRAGMENT_RESOLVED" <<'PY'
import json, os, sys
settings_path, fragment_path = sys.argv[1], sys.argv[2]

if os.path.exists(settings_path) and os.path.getsize(settings_path) > 0:
    try:
        with open(settings_path) as f:
            existing = json.load(f)
    except json.JSONDecodeError as e:
        print(f"ERROR: existing settings.json is invalid JSON: {e}", file=sys.stderr)
        print("Refusing to overwrite. Fix or remove it, then re-run.", file=sys.stderr)
        sys.exit(2)
else:
    existing = {}

with open(fragment_path) as f:
    fragment = json.load(f)

def merge(a, b):
    for k, v in b.items():
        if k in a and isinstance(a[k], dict) and isinstance(v, dict):
            merge(a[k], v)
        elif k in a and isinstance(a[k], list) and isinstance(v, list):
            a[k] = a[k] + v
        else:
            a[k] = v
    return a

merged = merge(existing if isinstance(existing, dict) else {}, fragment)

with open(settings_path, "w") as f:
    json.dump(merged, f, indent=2)
    f.write("\n")
PY

AGENT_COUNT=$(ls -1 "$CLAUDE_HOME/agents" 2>/dev/null | wc -l | tr -d ' ')
HOOK_COUNT=$(ls -1 "$CLAUDE_HOME/hooks" 2>/dev/null | wc -l | tr -d ' ')

echo
echo "Install complete."
echo "  Agents:   $AGENT_COUNT files at $CLAUDE_HOME/agents"
echo "  Hooks:    $HOOK_COUNT files at $CLAUDE_HOME/hooks"
echo "  Memory:   $CLAUDE_HOME/memory"
echo "  Settings: $SETTINGS"
[ -d "$BACKUP_DIR" ] && echo "  Backup:   $BACKUP_DIR"
echo
echo "Start a new Claude Code session to verify."
