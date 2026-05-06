# Phase 7: capture Task tool dispatches into a per-session "team activity"
# state file so the statusLine renderer can show which agent is working.
# Always exits 0 — never blocks tool execution.

$ErrorActionPreference = "SilentlyContinue"

$Input = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($Input)) { exit 0 }

$python = Get-Command python3 -ErrorAction SilentlyContinue
if (-not $python) { $python = Get-Command python -ErrorAction SilentlyContinue }
if (-not $python) { exit 0 }

$GlobalRoot = if ($env:LIBRARIAN_GLOBAL_ROOT) { $env:LIBRARIAN_GLOBAL_ROOT }
              elseif ($env:CLAUDE_HOME)        { $env:CLAUDE_HOME }
              else                              { Join-Path $env:USERPROFILE ".claude" }
$StateDir = Join-Path $GlobalRoot "state"
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

$pyScript = @'
import json, sys, datetime, pathlib

state_dir = pathlib.Path(sys.argv[1])
raw = sys.argv[2]

try:
    payload = json.loads(raw)
except json.JSONDecodeError:
    sys.exit(0)

if payload.get("tool_name") != "Task":
    sys.exit(0)

session_id = payload.get("session_id")
if not session_id:
    sys.exit(0)

ti = payload.get("tool_input") or {}
agent = ti.get("subagent_type") or "unknown"
desc = (ti.get("description") or "").strip()
prompt = ti.get("prompt") or ""

summary = desc
if not summary:
    for line in prompt.splitlines():
        s = line.strip()
        if not s:
            continue
        low = s.lower()
        if low.startswith("task:"):
            summary = s.split(":", 1)[1].strip()
            break
        if not low.startswith(("context:", "memory hints:", "deliverable:", "cap:", "mode:")):
            summary = s
            break
if len(summary) > 100:
    summary = summary[:99].rstrip() + "…"

state_path = state_dir / f"agents-{session_id}.json"
state = {"session_id": session_id, "agents": []}
if state_path.is_file():
    try:
        loaded = json.loads(state_path.read_text())
        if isinstance(loaded, dict):
            state = loaded
            state.setdefault("agents", [])
    except (OSError, json.JSONDecodeError):
        pass

now = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
state["agents"].append({
    "agent": agent,
    "description": summary,
    "status": "active",
    "started_at": now,
    "ended_at": None,
    "summary": None,
    "outcome": None,
})
state["agents"] = state["agents"][-30:]
state["session_id"] = session_id
state["updated_at"] = now

try:
    state_path.write_text(json.dumps(state, indent=2) + "\n")
except OSError:
    pass
'@

$tmp = New-TemporaryFile
Set-Content -Path $tmp -Value $pyScript -Encoding UTF8
try {
    & $python.Source $tmp $StateDir $Input | Out-Null
} finally {
    Remove-Item $tmp -ErrorAction SilentlyContinue
}

exit 0
