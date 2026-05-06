# Phase 4 + 5 + 6: enforce auditor + retrospective gates AND emit per-session
# telemetry summary on clean exit.
#
# Bypass gates: $env:CLAUDE_SKIP_AUDIT=1.
# Bypass telemetry: $env:CLAUDE_MULTIAGENT_NO_METRICS=1.

$ErrorActionPreference = "SilentlyContinue"

$Input = ""
try {
    if ([Console]::IsInputRedirected) {
        $Input = [Console]::In.ReadToEnd()
    }
} catch { $Input = "" }
if ([string]::IsNullOrWhiteSpace($Input)) { exit 0 }

try {
    $Payload = $Input | ConvertFrom-Json
} catch { exit 0 }

if ($Payload.stop_hook_active) { exit 0 }
if (-not $Payload.session_id)  { exit 0 }

$GlobalRoot = if ($env:LIBRARIAN_GLOBAL_ROOT) { $env:LIBRARIAN_GLOBAL_ROOT }
              elseif ($env:CLAUDE_HOME)      { $env:CLAUDE_HOME }
              else                           { Join-Path $env:USERPROFILE ".claude" }
$ProjectRoot = if ($env:LIBRARIAN_PROJECT_ROOT) { $env:LIBRARIAN_PROJECT_ROOT } else { (Get-Location).Path }

$StatePath  = Join-Path $GlobalRoot ("state\session-" + $Payload.session_id + ".json")
$MetricsDir = Join-Path $GlobalRoot "metrics"
New-Item -ItemType Directory -Force -Path $MetricsDir | Out-Null
$Jsonl = Join-Path $MetricsDir "sessions.jsonl"

$State = $null
if (Test-Path $StatePath) {
    try { $State = Get-Content -Raw -Path $StatePath | ConvertFrom-Json } catch { $State = $null }
}

# --- Gate enforcement ---
$SkipAudit = ($env:CLAUDE_SKIP_AUDIT -eq "1")
if ($State -and -not $SkipAudit) {
    $QaVerdicts = @()
    if ($State.qa_verdicts) { $QaVerdicts = @($State.qa_verdicts) }
    $RetroNeeded = [bool]$State.retro_needed
    # Audit M2: skip auditor gate when no engineering diff was produced.
    $DiffProduced = $true
    if ($null -ne $State.diff_produced) { $DiffProduced = [bool]$State.diff_produced }

    $Reasons = @()
    if ($QaVerdicts.Count -gt 0 -and $null -eq $State.auditor_verdict -and $DiffProduced) {
        $Reasons += "auditor not run - run the auditor agent against the original user request, the PLAN, all engineer CHANGES, and the QA verdicts before responding."
    }
    if ($RetroNeeded) {
        $Reasons += "corrections happened this session - run the retrospective agent against retro_prompts + the recent assistant turns + GATE_OUTPUTS, then dispatch librarian (mode: append) with its payload (or clear retro_needed if the retrospective decides this was a false positive)."
    }

    if ($Reasons.Count -gt 0) {
        $Bypass = " To bypass for this stop only, re-run Claude Code with the env var set: " +
                  "``$env:CLAUDE_SKIP_AUDIT=1; claude`` (PowerShell) or " +
                  "``CLAUDE_SKIP_AUDIT=1 claude`` (Unix). Use only if you have already " +
                  "verified the work yourself."
        $Out = @{
            decision = "block"
            reason   = ($Reasons -join " | ") + $Bypass
        } | ConvertTo-Json -Compress
        [Console]::Out.WriteLine($Out)
        exit 0
    }
}

# --- Per-session telemetry summary ---
if ($env:CLAUDE_MULTIAGENT_NO_METRICS -eq "1") { exit 0 }

$SessionId = [string]$Payload.session_id

$SubRecords = @()
if (Test-Path $Jsonl) {
    try {
        Get-Content -Path $Jsonl | ForEach-Object {
            if ([string]::IsNullOrWhiteSpace($_)) { return }
            try { $obj = $_ | ConvertFrom-Json } catch { return }
            if ($obj.kind -eq "subagent" -and $obj.session_id -eq $SessionId) { $SubRecords += $obj }
        }
    } catch { }
}

$HasWork = ($SubRecords.Count -gt 0) -or ($State -and (($State.qa_verdicts -and $State.qa_verdicts.Count -gt 0) -or $State.retro_needed))
if (-not $HasWork) { exit 0 }

function Sum-Field { param($recs, [string]$field)
    $vals = @()
    foreach ($r in $recs) {
        $v = $r.$field
        if ($v -is [int] -or $v -is [long] -or $v -is [double]) { $vals += $v }
    }
    if ($vals.Count -eq 0) { return $null }
    return ($vals | Measure-Object -Sum).Sum
}

$TotalInput  = Sum-Field $SubRecords "input_tokens"
$TotalOutput = Sum-Field $SubRecords "output_tokens"
$CacheRead   = Sum-Field $SubRecords "cache_read_tokens"; if ($null -eq $CacheRead)   { $CacheRead   = 0 }
$CacheCreate = Sum-Field $SubRecords "cache_creation_tokens"; if ($null -eq $CacheCreate) { $CacheCreate = 0 }
$DurationMs  = Sum-Field $SubRecords "duration_ms"

$CacheRate = $null
if ($TotalInput -and $TotalInput -gt 0) {
    $CacheRate = [math]::Round($CacheRead / $TotalInput, 3)
}

$Qa = @()
if ($State -and $State.qa_verdicts) { $Qa = @($State.qa_verdicts) }
$QaPassRate = $null
if ($Qa.Count -gt 0) {
    $pass = ($Qa | Where-Object { $_ -eq "pass" }).Count
    $QaPassRate = [math]::Round($pass / $Qa.Count, 3)
}

$Agents = @{}
foreach ($r in $SubRecords) { if ($r.agent) { $Agents[$r.agent] = $true } }
$TaskClass = "question"
if ($Agents["frontend-engineer"] -or $Agents["backend-engineer"] -or $Agents["test-engineer"]) { $TaskClass = "implement" }
elseif ($Agents["planner"]) { $TaskClass = "plan" }
elseif ($Agents["researcher"]) { $TaskClass = "research" }
elseif ($Agents["retrospective"]) { $TaskClass = "fix" }
elseif ($Agents.Count -gt 0) { $TaskClass = "other" }

$MistakesRecorded = ($SubRecords | Where-Object { $_.agent -eq "retrospective" -and -not $_.blocked }).Count

$RetroTriggered = $false
if ($State -and ($State.retro_needed -or $State.retro_prompts)) { $RetroTriggered = $true }

$Summary = [ordered]@{
    schema_version     = "1.0"
    kind               = "session"
    ts                 = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    session_id         = $SessionId
    project_root       = $ProjectRoot
    task_class         = $TaskClass
    subagent_count     = $SubRecords.Count
    total_input_tokens = $TotalInput
    total_output_tokens= $TotalOutput
    cache_hit_rate     = $CacheRate
    duration_ms        = $DurationMs
    auditor_verdict    = if ($State) { $State.auditor_verdict } else { $null }
    qa_pass_rate       = $QaPassRate
    retro_triggered    = $RetroTriggered
    mistakes_recorded  = $MistakesRecorded
}

try {
    Add-Content -Path $Jsonl -Value (($Summary | ConvertTo-Json -Compress -Depth 6)) -Encoding UTF8
} catch { }

exit 0
