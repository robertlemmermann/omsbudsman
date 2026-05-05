# Phase 5: detect correction signals in the user's prompt and set
# retro_needed=true on the session-state file. Broad regex on purpose -
# the retrospective agent is the second filter that drops false positives.
#
# Always exits 0 - this hook NEVER blocks the user's prompt.

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

$SessionId = [string]$Payload.session_id
$Prompt    = [string]$Payload.prompt
if ([string]::IsNullOrWhiteSpace($SessionId) -or [string]::IsNullOrWhiteSpace($Prompt)) {
    exit 0
}

$GlobalRoot = if ($env:LIBRARIAN_GLOBAL_ROOT) { $env:LIBRARIAN_GLOBAL_ROOT }
              elseif ($env:CLAUDE_HOME)      { $env:CLAUDE_HOME }
              else                           { Join-Path $env:USERPROFILE ".claude" }

$StateDir = Join-Path $GlobalRoot "state"
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

$Patterns = @(
    "\b(no|nope|wrong|incorrect|broken|fail(ed|ing)?|bug)\b",
    "\b(actually|instead|rather|but)\b.*\b(should|shouldn'?t|need(s|ed)?)\b",
    "\b(you|claude|the agent)\b.*\b(missed|forgot|didn'?t|should have|were supposed)\b",
    "\b(fix|revert|undo|rollback|redo)\b",
    "\b(why|how come)\b.*\b(did|didn'?t)\b",
    "\b(retrospective|post-?mortem|learn from this)\b"
)

$Hit = $false
foreach ($pat in $Patterns) {
    if ($Prompt -imatch $pat) { $Hit = $true; break }
}

if (-not $Hit) { exit 0 }

$StatePath = Join-Path $StateDir ("session-" + $SessionId + ".json")

$State = $null
if (Test-Path $StatePath) {
    try { $State = Get-Content -Raw -Path $StatePath | ConvertFrom-Json } catch { $State = $null }
}

if ($null -eq $State) {
    $State = [PSCustomObject]@{
        session_id      = $SessionId
        qa_verdicts     = @()
        auditor_verdict = $null
        retro_needed    = $true
        retro_prompts   = @()
    }
}

if (-not ($State.PSObject.Properties.Name -contains "qa_verdicts"))     { Add-Member -InputObject $State -NotePropertyName qa_verdicts     -NotePropertyValue @() -Force }
if (-not ($State.PSObject.Properties.Name -contains "auditor_verdict")) { Add-Member -InputObject $State -NotePropertyName auditor_verdict -NotePropertyValue $null -Force }
if (-not ($State.PSObject.Properties.Name -contains "retro_prompts"))   { Add-Member -InputObject $State -NotePropertyName retro_prompts   -NotePropertyValue @() -Force }

$State.retro_needed = $true

$Prompts = @()
if ($State.retro_prompts) { $Prompts = @($State.retro_prompts) }
$Prompts += $Prompt.Trim()
if ($Prompts.Count -gt 5) { $Prompts = $Prompts[-5..-1] }
$State.retro_prompts = $Prompts

try {
    $State | ConvertTo-Json -Depth 10 | Set-Content -Path $StatePath -Encoding UTF8
} catch { }

exit 0
