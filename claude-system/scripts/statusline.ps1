# Phase 7: render the multi-agent team's current activity as a single line for
# Claude Code's statusLine. Reads the agents-<session>.json written by the
# PreToolUse and SubagentStop hooks. Prints exactly one line; never errors.

$ErrorActionPreference = "SilentlyContinue"

$Input = ""
try {
    if ([Console]::IsInputRedirected) {
        $Input = [Console]::In.ReadToEnd()
    }
} catch { $Input = "" }

$python = Get-Command python3 -ErrorAction SilentlyContinue
if (-not $python) { $python = Get-Command python -ErrorAction SilentlyContinue }
if (-not $python) { Write-Output ""; exit 0 }

$GlobalRoot = if ($env:LIBRARIAN_GLOBAL_ROOT) { $env:LIBRARIAN_GLOBAL_ROOT }
              elseif ($env:CLAUDE_HOME)        { $env:CLAUDE_HOME }
              else                              { Join-Path $env:USERPROFILE ".claude" }
$StateDir = Join-Path $GlobalRoot "state"

$pyScript = @'
import json, os, sys, pathlib

state_dir = pathlib.Path(sys.argv[1])
raw = sys.argv[2] if len(sys.argv) > 2 else ""

try:
    payload = json.loads(raw) if raw else {}
except json.JSONDecodeError:
    payload = {}

session_id = payload.get("session_id") or os.environ.get("CLAUDE_SESSION_ID") or ""

LOOK = {
    "orchestrator":      ("🧭", "\033[38;5;51m"),
    "librarian":         ("📚", "\033[38;5;220m"),
    "researcher":        ("🔬", "\033[38;5;75m"),
    "planner":           ("📋", "\033[38;5;177m"),
    "backend-engineer":  ("⚙️ ", "\033[38;5;42m"),
    "frontend-engineer": ("🎨", "\033[38;5;208m"),
    "test-engineer":     ("🧪", "\033[38;5;213m"),
    "qa-reviewer":       ("🛡️ ", "\033[38;5;226m"),
    "auditor":           ("🔍", "\033[38;5;196m"),
    "retrospective":     ("🪞", "\033[38;5;245m"),
}
RESET = "\033[0m"; DIM = "\033[2m"; BOLD = "\033[1m"

STATUS = {
    "active":  ("●", "\033[38;5;226m"),
    "done":    ("✓", "\033[38;5;42m"),
    "blocked": ("✗", "\033[38;5;196m"),
    "failed":  ("✗", "\033[38;5;196m"),
}
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
    print(f"🧭 {DIM}team idle (no session){RESET}"); sys.exit(0)

state_path = state_dir / f"agents-{session_id}.json"
if not state_path.is_file():
    print(f"🧭 {DIM}team idle — awaiting first dispatch{RESET}"); sys.exit(0)

try:
    state = json.loads(state_path.read_text())
except (OSError, json.JSONDecodeError):
    state = {}

agents = state.get("agents") or []
if not agents:
    print(f"🧭 {DIM}team idle{RESET}"); sys.exit(0)

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

trail_parts = []
for a in agents[-7:]:
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

print(f"{headline}  {DIM}│{RESET}  {trail}")
'@

$tmp = New-TemporaryFile
Set-Content -Path $tmp -Value $pyScript -Encoding UTF8
try {
    & $python.Source $tmp $StateDir $Input
} catch {
    Write-Output ""
} finally {
    Remove-Item $tmp -ErrorAction SilentlyContinue
}

exit 0
