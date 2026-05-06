#!/usr/bin/env bash
# Phase 7: render the multi-agent team's current activity as a single line for
# Claude Code's statusLine. Reads the agents-<session>.json written by the
# PreToolUse and SubagentStop hooks. Prints exactly one line; never errors.
set -e

INPUT="$(cat 2>/dev/null || true)"

GLOBAL_ROOT="${LIBRARIAN_GLOBAL_ROOT:-${CLAUDE_HOME:-$HOME/.claude}}"
STATE_DIR="$GLOBAL_ROOT/state"

if ! command -v python3 >/dev/null 2>&1; then
  printf "%s" ""
  exit 0
fi

python3 - "$STATE_DIR" "$INPUT" <<'PY' 2>/dev/null || printf ""
import json, os, sys, pathlib

state_dir = pathlib.Path(sys.argv[1])
raw = sys.argv[2] if len(sys.argv) > 2 else ""

try:
    payload = json.loads(raw) if raw else {}
except json.JSONDecodeError:
    payload = {}

session_id = (
    payload.get("session_id")
    or os.environ.get("CLAUDE_SESSION_ID")
    or ""
)

# Per-agent emoji + ANSI 256-color foreground codes.
LOOK = {
    "orchestrator":      ("🧭", "\033[38;5;51m"),   # bright cyan
    "librarian":         ("📚", "\033[38;5;220m"),  # gold
    "researcher":        ("🔬", "\033[38;5;75m"),   # blue
    "planner":           ("📋", "\033[38;5;177m"),  # violet
    "backend-engineer":  ("⚙️ ", "\033[38;5;42m"),  # green
    "frontend-engineer": ("🎨", "\033[38;5;208m"),  # orange
    "test-engineer":     ("🧪", "\033[38;5;213m"),  # pink
    "qa-reviewer":       ("🛡️ ", "\033[38;5;226m"), # yellow
    "auditor":           ("🔍", "\033[38;5;196m"),  # red
    "retrospective":     ("🪞", "\033[38;5;245m"),  # gray
}
RESET = "\033[0m"
DIM   = "\033[2m"
BOLD  = "\033[1m"

# status → (dot glyph, ANSI color)
STATUS = {
    "active":  ("●", "\033[38;5;226m"),   # yellow pulse
    "done":    ("✓", "\033[38;5;42m"),    # green check
    "blocked": ("✗", "\033[38;5;196m"),   # red x
    "failed":  ("✗", "\033[38;5;196m"),
}

# Override outcome glyphs for gate agents (qa/auditor) so the verdict shows.
OUTCOME = {
    "pass":     ("✓", "\033[38;5;42m"),
    "fail":     ("✗", "\033[38;5;196m"),
    "approve":  ("✓", "\033[38;5;42m"),
    "revise":   ("↻", "\033[38;5;208m"),
    "escalate": ("!", "\033[38;5;201m"),
}

def short(s, n):
    s = (s or "").strip()
    return (s[:n-1] + "…") if len(s) > n else s

if not session_id:
    print(f"🧭 {DIM}team idle (no session){RESET}")
    sys.exit(0)

state_path = state_dir / f"agents-{session_id}.json"
if not state_path.is_file():
    print(f"🧭 {DIM}team idle — awaiting first dispatch{RESET}")
    sys.exit(0)

try:
    state = json.loads(state_path.read_text())
except (OSError, json.JSONDecodeError):
    state = {}

agents = state.get("agents") or []
if not agents:
    print(f"🧭 {DIM}team idle{RESET}")
    sys.exit(0)

# Latest active agent → headline. If none active, use the most recent done.
active = [a for a in agents if a.get("status") == "active"]
head_agent = active[-1] if active else agents[-1]

name = head_agent.get("agent") or "?"
emoji, color = LOOK.get(name, ("•", ""))
status = head_agent.get("status") or "active"
outcome = head_agent.get("outcome")

if status == "active":
    glyph, gcolor = STATUS["active"]
    label = head_agent.get("description") or "working…"
else:
    if outcome and outcome in OUTCOME:
        glyph, gcolor = OUTCOME[outcome]
    else:
        glyph, gcolor = STATUS.get(status, STATUS["done"])
    label = head_agent.get("summary") or head_agent.get("description") or ""

headline = f"{color}{BOLD}{emoji} {name}{RESET} {gcolor}{glyph}{RESET} {short(label, 70)}"

# Trail: compact glyphs for the last few agents so the user can see flow.
trail_entries = agents[-7:]
trail_parts = []
for a in trail_entries:
    n = a.get("agent") or "?"
    e, c = LOOK.get(n, ("•", ""))
    st = a.get("status") or "active"
    oc = a.get("outcome")
    if oc and oc in OUTCOME:
        g, gc = OUTCOME[oc]
    else:
        g, gc = STATUS.get(st, STATUS["done"])
    trail_parts.append(f"{c}{e}{RESET}{gc}{g}{RESET}")
trail = " ".join(trail_parts)

# Compose: headline   │   trail
print(f"{headline}  {DIM}│{RESET}  {trail}")
PY

exit 0
