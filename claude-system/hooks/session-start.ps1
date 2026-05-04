# Phase 3: bootstrap per-project memory tier, export librarian env vars, and
# inject the orchestrator persona into the main session via additionalContext.
# Must exit 0 so it never blocks session startup.

$ErrorActionPreference = "Stop"

# Locate project root: git toplevel, fall back to cwd.
$ProjectRoot = $null
try {
    $ProjectRoot = (git rev-parse --show-toplevel 2>$null).Trim()
} catch { }
if (-not $ProjectRoot) {
    $ProjectRoot = (Get-Location).Path
}

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

$GlobalRoot = if ($env:CLAUDE_HOME) { $env:CLAUDE_HOME } else { Join-Path $env:USERPROFILE ".claude" }
$env:LIBRARIAN_PROJECT_ROOT = $ProjectRoot
$env:LIBRARIAN_GLOBAL_ROOT  = $GlobalRoot

# Inject orchestrator persona into the main session via SessionStart additionalContext.
$OrchestratorFile = Join-Path $GlobalRoot "agents\orchestrator.md"
$Ctx = @"
Adopt the persona defined in $OrchestratorFile for this entire session. You are the orchestrator: a router. Your only tool is Task. Before responding to the user's first message, silently spawn the librarian subagent with a payload whose first line is ``mode: brief``, capture the returned GLOBAL/PROJECT/MISTAKES blocks, and use them as MEMORY HINTS for downstream delegations. Do not narrate the brief. Do not paste subagent output verbatim. Classify intent (pure question / plan / implementation / trivial / conversational) and dispatch researcher -> planner -> engineers -> qa-reviewer -> auditor as appropriate. Read $OrchestratorFile now if you have not already.
"@

$Payload = @{
    hookSpecificOutput = @{
        hookEventName     = "SessionStart"
        additionalContext = $Ctx
    }
} | ConvertTo-Json -Compress -Depth 4

[Console]::Out.WriteLine($Payload)
[Console]::Error.WriteLine("[claude-multi-agent] memory tiers ready: $GlobalRoot\memory + $ProjectMemoryDir")
exit 0
