# Phase 2: bootstrap per-project memory tier and signal librarian to load brief.
# The orchestrator (phase 3) actually invokes the librarian; this hook only
# prepares the filesystem and exports env vars the agent reads.
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

[Console]::Error.WriteLine("[claude-multi-agent] memory tiers ready: $GlobalRoot\memory + $ProjectMemoryDir")
exit 0
