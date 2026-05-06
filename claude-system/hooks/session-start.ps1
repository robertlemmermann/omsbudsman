# Phase 4: bootstrap per-project memory tier, export librarian env vars,
# bake session id + state path into the orchestrator persona via
# additionalContext, and inject the orchestrator persona itself.
# Must exit 0 so it never blocks session startup.

$ErrorActionPreference = "Stop"

# Read SessionStart payload (Claude Code passes session_id, etc. as JSON on stdin).
# Tolerate empty stdin in test harnesses.
$HookInput = ""
try {
    if (-not [Console]::IsInputRedirected) {
        $HookInput = ""
    } else {
        $HookInput = [Console]::In.ReadToEnd()
    }
} catch { $HookInput = "" }

$SessionId = ""
if (-not [string]::IsNullOrWhiteSpace($HookInput)) {
    try {
        $Parsed = $HookInput | ConvertFrom-Json
        if ($Parsed.session_id) { $SessionId = [string]$Parsed.session_id }
    } catch { $SessionId = "" }
}

# Locate project root via explicit markers — never let bare cwd define
# project identity (audit P2.3). Walk up looking for git, .claude/memory,
# or a known stack manifest.
function Find-ProjectRoot {
    $dir = (Get-Location).Path
    while ($dir -and $dir -ne (Split-Path $dir -Parent)) {
        if ((Test-Path (Join-Path $dir ".git")) `
            -or (Test-Path (Join-Path $dir ".claude\memory")) `
            -or (Test-Path (Join-Path $dir "package.json")) `
            -or (Test-Path (Join-Path $dir "pyproject.toml")) `
            -or (Test-Path (Join-Path $dir "Cargo.toml")) `
            -or (Test-Path (Join-Path $dir "go.mod"))) {
            return $dir
        }
        $dir = Split-Path $dir -Parent
    }
    return $null
}

$ProjectRoot = $null
try {
    $ProjectRoot = (git rev-parse --show-toplevel 2>$null)
    if ($ProjectRoot) { $ProjectRoot = $ProjectRoot.Trim() }
} catch { }
if (-not $ProjectRoot) {
    $ProjectRoot = Find-ProjectRoot
}

$ProjectMemoryDir = $null
if ($ProjectRoot) {
    $ProjectMemoryDir = Join-Path $ProjectRoot ".claude\memory"
    $MistakesDir      = Join-Path $ProjectMemoryDir "mistakes"

    New-Item -ItemType Directory -Force -Path $MistakesDir | Out-Null

    $ProjectIndex = Join-Path $ProjectMemoryDir "INDEX.md"
    if (-not (Test-Path $ProjectIndex)) {
@'
# Memory Index - Project

> Last updated: (none) - Entries: 0

Project-tier memory. Maintained by the librarian agent.

## Layout

- `project.md` - stack, conventions, gotchas, architecture notes
- `decisions.md` - project-specific decisions with rationale
- `mistakes/INDEX.md` - tag to file map for prevention rules
- `mistakes/<topic>.md` - prevention rules for this codebase
'@ | Set-Content -Path $ProjectIndex -Encoding UTF8
    }

    $MistakesIndex = Join-Path $MistakesDir "INDEX.md"
    if (-not (Test-Path $MistakesIndex)) {
@'
# Mistakes Index - Project

> Last updated: (none) - Entries: 0

Tag to file map for project-specific prevention rules.
'@ | Set-Content -Path $MistakesIndex -Encoding UTF8
    }
}

$GlobalRoot = if ($env:CLAUDE_HOME) { $env:CLAUDE_HOME } else { Join-Path $env:USERPROFILE ".claude" }
# Empty LIBRARIAN_PROJECT_ROOT signals global-only operation downstream.
if ($ProjectRoot) {
    $env:LIBRARIAN_PROJECT_ROOT = $ProjectRoot
} else {
    $env:LIBRARIAN_PROJECT_ROOT = ""
}
$env:LIBRARIAN_GLOBAL_ROOT  = $GlobalRoot

$StateDir = Join-Path $GlobalRoot "state"
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

# Inject orchestrator persona into the main session via SessionStart additionalContext.
$OrchestratorFile = Join-Path $GlobalRoot "agents\orchestrator.md"

if ($SessionId) {
    $StatePath = Join-Path $StateDir ("session-" + $SessionId + ".json")
    $StateClause = "Your gate-state file is $StatePath. Initialize it with {`"session_id`": `"$SessionId`", `"qa_verdicts`": [], `"auditor_verdict`": null, `"retro_needed`": false} before the first QA dispatch. Append each QA verdict (pass/fail) to qa_verdicts as it returns. Set auditor_verdict to the auditor's approve/revise/escalate string immediately after the auditor runs. The Stop hook reads this file and refuses clean termination if qa_verdicts is non-empty and auditor_verdict is null."
} else {
    $StateClause = "Session id was not provided by the harness; gate-state recording is disabled this session. Run all gates manually and do not rely on the Stop hook to flag a missed audit."
}

$Ctx = @"
Adopt the persona defined in $OrchestratorFile for this entire session. You are the orchestrator: a router. Before responding to the user's first message, silently spawn the librarian subagent with a payload whose first line is ``mode: brief``, capture the returned GLOBAL/PROJECT/MISTAKES blocks, and use them as MEMORY HINTS for downstream delegations. Do not narrate the brief. Do not paste subagent output verbatim. Classify intent (pure question / plan / implementation / trivial / conversational) and dispatch researcher -> planner -> engineers (frontend/backend/test) -> qa-reviewer -> auditor as appropriate. Use Bash only to maintain the gate-state file described next; use no other file/shell tools yourself. $StateClause Read $OrchestratorFile now if you have not already.
"@

$Payload = @{
    hookSpecificOutput = @{
        hookEventName     = "SessionStart"
        additionalContext = $Ctx
    }
} | ConvertTo-Json -Compress -Depth 4

[Console]::Out.WriteLine($Payload)
if ($ProjectMemoryDir) {
    [Console]::Error.WriteLine("[claude-multi-agent] memory tiers ready: $GlobalRoot\memory + $ProjectMemoryDir")
} else {
    [Console]::Error.WriteLine("[claude-multi-agent] memory ready (global-only - no project marker found at $((Get-Location).Path) or above)")
}
exit 0
