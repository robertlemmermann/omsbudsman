# Phase 4 + 5: enforce the auditor and retrospective gates.
#
# Read JSON from stdin (Claude Code Stop-hook contract). Look up the
# session-state file the orchestrator writes at each gate.
# Block clean termination if either:
#   (a) qa_verdicts is non-empty AND auditor_verdict is null  -> auditor missing
#   (b) retro_needed is true                                  -> retrospective missing
#
# Bypass: set $env:CLAUDE_SKIP_AUDIT=1 (skips both blocks).
#
# Phase 6 will extend this hook for telemetry.

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
$RetroNeeded = [bool]$State.retro_needed

$Reasons = @()

if ($QaVerdicts.Count -gt 0 -and $null -eq $State.auditor_verdict) {
    $Reasons += "auditor not run - run the auditor agent against the original user request, the PLAN, all engineer CHANGES, and the QA verdicts before responding."
}

if ($RetroNeeded) {
    $Reasons += "corrections happened this session - run the retrospective agent against retro_prompts + the recent assistant turns + GATE_OUTPUTS, then dispatch librarian (mode: append) with its payload (or clear retro_needed if the retrospective decides this was a false positive)."
}

if ($Reasons.Count -gt 0) {
    $Out = @{
        decision = "block"
        reason   = ($Reasons -join " | ") + " Set CLAUDE_SKIP_AUDIT=1 to bypass for this stop only."
    } | ConvertTo-Json -Compress
    [Console]::Out.WriteLine($Out)
}

exit 0
