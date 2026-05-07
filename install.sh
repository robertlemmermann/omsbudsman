#!/usr/bin/env bash
# Installer for the Claude Code multi-agent system (macOS / Linux).
# Idempotent — re-runs are safe and create a fresh backup each time.
set -euo pipefail

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$SCRIPT_DIR/claude-system"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="$HOME/.claude.backup-$TIMESTAMP"
SOURCE_VERSION="$(cat "$SOURCE_DIR/VERSION" 2>/dev/null | tr -d '[:space:]')"

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

mkdir -p "$CLAUDE_HOME/agents" "$CLAUDE_HOME/hooks" "$CLAUDE_HOME/memory" "$CLAUDE_HOME/state" "$CLAUDE_HOME/metrics" "$CLAUDE_HOME/scripts"

echo "Installing agents..."
cp "$SOURCE_DIR/agents/"*.md "$CLAUDE_HOME/agents/"

echo "Installing hooks..."
cp "$SOURCE_DIR/hooks/"* "$CLAUDE_HOME/hooks/"
chmod +x "$CLAUDE_HOME/hooks/"*.sh

if [ -d "$SOURCE_DIR/scripts" ]; then
  echo "Installing scripts..."
  cp "$SOURCE_DIR/scripts/"* "$CLAUDE_HOME/scripts/"
  chmod +x "$CLAUDE_HOME/scripts/"*.sh 2>/dev/null || true
fi

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
HOOK_CMD_USER_PROMPT_SUBMIT="$CLAUDE_HOME/hooks/user-prompt-submit.sh"
HOOK_CMD_SUBAGENT_STOP="$CLAUDE_HOME/hooks/subagent-stop.sh"
HOOK_CMD_STOP="$CLAUDE_HOME/hooks/stop.sh"
sed -e "s|{{HOOK_CMD_SESSION_START}}|$HOOK_CMD_SESSION_START|g" \
    -e "s|{{HOOK_CMD_USER_PROMPT_SUBMIT}}|$HOOK_CMD_USER_PROMPT_SUBMIT|g" \
    -e "s|{{HOOK_CMD_SUBAGENT_STOP}}|$HOOK_CMD_SUBAGENT_STOP|g" \
    -e "s|{{HOOK_CMD_STOP}}|$HOOK_CMD_STOP|g" \
    "$FRAGMENT_RAW" > "$FRAGMENT_RESOLVED"

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

# Write version stamp only after a fully successful install.
[ -n "$SOURCE_VERSION" ] && printf '%s\n' "$SOURCE_VERSION" > "$CLAUDE_HOME/VERSION"

AGENT_COUNT=$(ls -1 "$CLAUDE_HOME/agents" 2>/dev/null | wc -l | tr -d ' ')
HOOK_COUNT=$(ls -1 "$CLAUDE_HOME/hooks" 2>/dev/null | wc -l | tr -d ' ')
SCRIPT_COUNT=$(ls -1 "$CLAUDE_HOME/scripts" 2>/dev/null | wc -l | tr -d ' ')

echo
echo "Install complete."
echo "  Version:  ${SOURCE_VERSION:-unknown}"
echo "  Agents:   $AGENT_COUNT files at $CLAUDE_HOME/agents"
echo "  Hooks:    $HOOK_COUNT files at $CLAUDE_HOME/hooks"
echo "  Scripts:  $SCRIPT_COUNT files at $CLAUDE_HOME/scripts"
echo "  Memory:   $CLAUDE_HOME/memory"
echo "  Metrics:  $CLAUDE_HOME/metrics"
echo "  Settings: $SETTINGS"
[ -d "$BACKUP_DIR" ] && echo "  Backup:   $BACKUP_DIR"
echo
echo "Start a new Claude Code session to verify."
echo "Run $CLAUDE_HOME/scripts/metrics.sh after a few sessions for cost/perf reports."
echo "Set CLAUDE_MULTIAGENT_NO_METRICS=1 to disable telemetry."
# TODO: migrate.ps1 (Windows in-place migration) is a follow-up; see migrate.sh for the bash equivalent.
