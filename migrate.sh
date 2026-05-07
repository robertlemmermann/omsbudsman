#!/usr/bin/env bash
# In-place migration for the Claude Code multi-agent system (macOS / Linux).
# Upgrades an existing ~/.claude/ install to the version in claude-system/VERSION.
# Preserves memory/, state/, and metrics/. Merges settings.json.
# Idempotent: already-current installs exit 0 with no changes.
set -euo pipefail

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$SCRIPT_DIR/claude-system"

if [ ! -d "$SOURCE_DIR" ]; then
  echo "ERROR: source directory not found: $SOURCE_DIR" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required for the settings merge step." >&2
  exit 1
fi

SOURCE_VERSION="$(cat "$SOURCE_DIR/VERSION" 2>/dev/null | tr -d '[:space:]')"
if [ -z "$SOURCE_VERSION" ]; then
  echo "ERROR: $SOURCE_DIR/VERSION is missing or empty." >&2
  exit 1
fi

INSTALLED_VERSION="$(cat "$CLAUDE_HOME/VERSION" 2>/dev/null | tr -d '[:space:]')"

# semver_lte A B — returns 0 (true) when A <= B using sort -V.
semver_lte() {
  [ "$(printf '%s\n%s' "$1" "$2" | sort -V | head -1)" = "$1" ]
}

if [ -n "$INSTALLED_VERSION" ] && semver_lte "$SOURCE_VERSION" "$INSTALLED_VERSION"; then
  echo "already up to date (installed=$INSTALLED_VERSION, source=$SOURCE_VERSION)"
  exit 0
fi

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
PREMIGRATE_DIR="$HOME/.claude.premigrate-$TIMESTAMP"

echo "Migrating ${INSTALLED_VERSION:-<fresh>} -> $SOURCE_VERSION"
echo "Backing up $CLAUDE_HOME -> $PREMIGRATE_DIR"
cp -R "$CLAUDE_HOME" "$PREMIGRATE_DIR"

mkdir -p "$CLAUDE_HOME/agents" "$CLAUDE_HOME/hooks" "$CLAUDE_HOME/scripts"

echo "Replacing agents..."
ADDED_AGENTS=0
REPLACED_AGENTS=0
for src in "$SOURCE_DIR/agents/"*.md; do
  name="$(basename "$src")"
  dest="$CLAUDE_HOME/agents/$name"
  if [ -f "$dest" ]; then
    REPLACED_AGENTS=$((REPLACED_AGENTS + 1))
  else
    ADDED_AGENTS=$((ADDED_AGENTS + 1))
  fi
  cp "$src" "$dest"
done

echo "Replacing hooks..."
ADDED_HOOKS=0
REPLACED_HOOKS=0
for src in "$SOURCE_DIR/hooks/"*; do
  name="$(basename "$src")"
  dest="$CLAUDE_HOME/hooks/$name"
  if [ -f "$dest" ]; then
    REPLACED_HOOKS=$((REPLACED_HOOKS + 1))
  else
    ADDED_HOOKS=$((ADDED_HOOKS + 1))
  fi
  cp "$src" "$dest"
done
chmod +x "$CLAUDE_HOME/hooks/"*.sh

if [ -d "$SOURCE_DIR/scripts" ]; then
  echo "Replacing scripts..."
  ADDED_SCRIPTS=0
  REPLACED_SCRIPTS=0
  for src in "$SOURCE_DIR/scripts/"*; do
    name="$(basename "$src")"
    dest="$CLAUDE_HOME/scripts/$name"
    if [ -f "$dest" ]; then
      REPLACED_SCRIPTS=$((REPLACED_SCRIPTS + 1))
    else
      ADDED_SCRIPTS=$((ADDED_SCRIPTS + 1))
    fi
    cp "$src" "$dest"
  done
  chmod +x "$CLAUDE_HOME/scripts/"*.sh 2>/dev/null || true
fi

# memory/, state/, metrics/ are intentionally left untouched.

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

# Write new version only after all steps succeed.
printf '%s\n' "$SOURCE_VERSION" > "$CLAUDE_HOME/VERSION"

echo
echo "Migration complete: ${INSTALLED_VERSION:-<fresh>} -> $SOURCE_VERSION"
echo "  Agents:   added=$ADDED_AGENTS replaced=$REPLACED_AGENTS"
echo "  Hooks:    added=$ADDED_HOOKS replaced=$REPLACED_HOOKS"
echo "  Scripts:  added=${ADDED_SCRIPTS:-0} replaced=${REPLACED_SCRIPTS:-0}"
echo "  memory/, state/, metrics/: untouched"
echo "  Settings: $SETTINGS (merged)"
echo "  Backup:   $PREMIGRATE_DIR"
echo "  Version:  $CLAUDE_HOME/VERSION"
echo
echo "Start a new Claude Code session to verify."
# TODO: migrate.ps1 (Windows in-place migration) is a follow-up to this script.
