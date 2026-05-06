# Phase 6: per-subagent telemetry. Append one JSONL record per Task return.
# Must exit 0 fast - never blocks.
#
# Opt out by setting $env:CLAUDE_MULTIAGENT_NO_METRICS=1.

$ErrorActionPreference = "SilentlyContinue"

if ($env:CLAUDE_MULTIAGENT_NO_METRICS -eq "1") { exit 0 }

$Input = ""
try {
    if ([Console]::IsInputRedirected) {
        $Input = [Console]::In.ReadToEnd()
    }
} catch { $Input = "" }
if ([string]::IsNullOrWhiteSpace($Input)) { exit 0 }

try {
    $Payload = $Input | ConvertFrom-Json
} catch {
    exit 0
}

$GlobalRoot = if ($env:LIBRARIAN_GLOBAL_ROOT) { $env:LIBRARIAN_GLOBAL_ROOT }
              elseif ($env:CLAUDE_HOME)      { $env:CLAUDE_HOME }
              else                           { Join-Path $env:USERPROFILE ".claude" }

$ProjectRoot = if ($env:LIBRARIAN_PROJECT_ROOT) { $env:LIBRARIAN_PROJECT_ROOT } else { (Get-Location).Path }

$MetricsDir = Join-Path $GlobalRoot "metrics"
New-Item -ItemType Directory -Force -Path $MetricsDir | Out-Null
$Jsonl = Join-Path $MetricsDir "sessions.jsonl"

$Usage = $null
if ($Payload.usage)              { $Usage = $Payload.usage }
elseif ($Payload.subagent.usage) { $Usage = $Payload.subagent.usage }

function Get-Or-Null { param($obj, [string[]]$path)
    $cur = $obj
    foreach ($k in $path) {
        if ($null -eq $cur) { return $null }
        $cur = $cur.$k
    }
    return $cur
}

$Agent = $Payload.subagent_type
if (-not $Agent) { $Agent = Get-Or-Null $Payload @('subagent','type') }
if (-not $Agent) { $Agent = $Payload.agent }

$Model = $Payload.model
if (-not $Model) { $Model = Get-Or-Null $Payload @('subagent','model') }

$DurationMs = $Payload.duration_ms
if ($null -eq $DurationMs) { $DurationMs = Get-Or-Null $Payload @('subagent','duration_ms') }

$Outcome = $Payload.outcome
if (-not $Outcome) { if ($Payload.blocked) { $Outcome = "blocked" } else { $Outcome = "ok" } }

$CacheRead     = $null; if ($Usage) { if ($Usage.cache_read_input_tokens)     { $CacheRead     = $Usage.cache_read_input_tokens }     else { $CacheRead     = $Usage.cache_read_tokens } }
$CacheCreation = $null; if ($Usage) { if ($Usage.cache_creation_input_tokens) { $CacheCreation = $Usage.cache_creation_input_tokens } else { $CacheCreation = $Usage.cache_creation_tokens } }
$InputTokens   = if ($Usage) { $Usage.input_tokens }  else { $null }
$OutputTokens  = if ($Usage) { $Usage.output_tokens } else { $null }

$Record = [ordered]@{
    kind                  = "subagent"
    ts                    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    session_id            = [string]$Payload.session_id
    project_root          = $ProjectRoot
    agent                 = $Agent
    model                 = $Model
    input_tokens          = $InputTokens
    output_tokens         = $OutputTokens
    cache_read_tokens     = $CacheRead
    cache_creation_tokens = $CacheCreation
    duration_ms           = $DurationMs
    blocked               = [bool]$Payload.blocked
    outcome               = $Outcome
}

try {
    if (Test-Path $Jsonl) {
        $size = (Get-Item $Jsonl).Length
        if ($size -gt (10 * 1024 * 1024)) {
            $tag = (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss")
            $archive = Join-Path $MetricsDir ("sessions.$tag.jsonl.gz")
            $fs  = [IO.File]::OpenRead($Jsonl)
            $out = [IO.File]::Create($archive)
            $gz  = New-Object IO.Compression.GZipStream($out, [IO.Compression.CompressionMode]::Compress)
            $fs.CopyTo($gz); $gz.Dispose(); $out.Dispose(); $fs.Dispose()
            Set-Content -Path $Jsonl -Value "" -Encoding UTF8 -NoNewline
            $archives = Get-ChildItem -Path $MetricsDir -Filter "sessions.*.jsonl.gz" | Sort-Object LastWriteTime
            if ($archives.Count -gt 4) {
                $archives | Select-Object -First ($archives.Count - 4) | Remove-Item -Force
            }
        }
    }
} catch { }

try {
    Add-Content -Path $Jsonl -Value (($Record | ConvertTo-Json -Compress -Depth 6)) -Encoding UTF8
} catch { }

# --- Team activity state update (for statusLine renderer) ---
$SessionId = [string]$Payload.session_id
if ($SessionId -and $Agent) {
    $StateDir = Join-Path $GlobalRoot "state"
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    $StatePath = Join-Path $StateDir "agents-$SessionId.json"

    if (Test-Path $StatePath) {
        try {
            $AState = Get-Content -Raw -Path $StatePath | ConvertFrom-Json
        } catch { $AState = $null }

        if ($AState -and $AState.agents) {
            $Response = $Payload.response
            if (-not $Response) { $Response = Get-Or-Null $Payload @('subagent','response') }
            if (-not $Response) { $Response = $Payload.result }
            if ($Response -is [System.Collections.IEnumerable] -and -not ($Response -is [string])) {
                $Pieces = @()
                foreach ($blk in $Response) {
                    if ($blk.text) { $Pieces += [string]$blk.text }
                }
                $Response = ($Pieces -join "`n")
            }
            if ($null -eq $Response) { $Response = "" }
            $Response = [string]$Response

            $SummaryLine = ""
            foreach ($line in ($Response -split "`n")) {
                $s = $line.Trim()
                if ($s -and -not ($s.StartsWith("```") -or $s.StartsWith("---") -or $s.StartsWith("==="))) {
                    $SummaryLine = $s
                    break
                }
            }
            if ($SummaryLine.Length -gt 100) { $SummaryLine = $SummaryLine.Substring(0,99).TrimEnd() + "…" }

            $LowResp = $Response.ToLower()
            $Outcome2 = if ($Payload.blocked) { "blocked" } else { "ok" }
            if ($Agent -eq "qa-reviewer") {
                if ($LowResp.Contains("verdict: pass")) { $Outcome2 = "pass" }
                elseif ($LowResp.Contains("verdict: fail")) { $Outcome2 = "fail" }
            } elseif ($Agent -eq "auditor") {
                foreach ($v in @("approve","revise","escalate")) {
                    if ($LowResp.Contains("verdict: $v")) { $Outcome2 = $v; break }
                }
            }

            $Status = if ($Payload.blocked) { "blocked" }
                      elseif ($Outcome2 -eq "fail") { "failed" }
                      else { "done" }

            $Matched = $false
            for ($i = $AState.agents.Count - 1; $i -ge 0; $i--) {
                $entry = $AState.agents[$i]
                if ($entry.agent -eq $Agent -and $entry.status -eq "active") {
                    $entry.status     = $Status
                    $entry.ended_at   = $Record.ts
                    $entry.summary    = if ($SummaryLine) { $SummaryLine } else { $null }
                    $entry.outcome    = $Outcome2
                    $Matched = $true
                    break
                }
            }
            if (-not $Matched) {
                $newEntry = [ordered]@{
                    agent       = $Agent
                    description = ""
                    status      = $Status
                    started_at  = $Record.ts
                    ended_at    = $Record.ts
                    summary     = if ($SummaryLine) { $SummaryLine } else { $null }
                    outcome     = $Outcome2
                }
                $AState.agents = @($AState.agents) + (New-Object psobject -Property $newEntry)
                if ($AState.agents.Count -gt 30) {
                    $AState.agents = $AState.agents[-30..-1]
                }
            }
            $AState.updated_at = $Record.ts
            try {
                ($AState | ConvertTo-Json -Depth 8) | Set-Content -Path $StatePath -Encoding UTF8
            } catch { }
        }
    }
}

exit 0
