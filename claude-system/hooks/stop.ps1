# Phase 4: enforce the auditor gate.
#
# Read JSON from stdin (Claude Code Stop-hook contract). Look up the
# session-state file the orchestrator writes at each gate. If any QA
# verdicts were recorded but auditor_verdict is null, emit a JSON
# "decision: block" message so the orchestrator must run the auditor.
#
# Bypass: set $env:CLAUDE_SKIP_AUDIT=1 for the rare case the user is
# mid-work and wants to stop without auditing.
#
# Phases 5 and 6 will extend this hook for retrospective + telemetry.

$ErrorActionPreference = "SilentlyContinue"

if ($env:CLAUDE_SKIP_AUDIT -eq "1") { exit 0 }

$Input = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($Input)) { exit 0 }

try {
    $Payload = $Input | ConvertFrom-Json
} catch {
    exit 0
}

if ($Payload.stop_hook_active) { exit 0 }
if (-not $Payload.session_id)  { exit 0 }

$GlobalRoot = if ($env:LIBRARIAN_GLOBAL_ROOT) { $env:LIBRARIAN_GLOBAL_ROOT }
              elseif ($env:CLAUDE_HOME)      { $env:CLAUDE_HOME }
              else                           { Join-Path $env:USERPROFILE ".claude" }

$StatePath = Join-Path $GlobalRoot ("state\session-" + $Payload.session_id + ".json")
if (-not (Test-Path $StatePath)) { exit 0 }

try {
    $State = Get-Content -Raw -Path $StatePath | ConvertFrom-Json
} catch {
    exit 0
}

$QaVerdicts = @()
if ($State.qa_verdicts) { $QaVerdicts = @($State.qa_verdicts) }

if ($QaVerdicts.Count -gt 0 -and $null -eq $State.auditor_verdict) {
    $Out = @{
        decision = "block"
        reason   = "auditor not run - run the auditor agent against the original user request, the PLAN, all engineer CHANGES, and the QA verdicts before responding. Set CLAUDE_SKIP_AUDIT=1 to bypass for this stop only."
    } | ConvertTo-Json -Compress
    [Console]::Out.WriteLine($Out)
}

exit 0
