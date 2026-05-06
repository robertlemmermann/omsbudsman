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

$ClaudeCodeVersion = $Payload.claude_code_version
if (-not $ClaudeCodeVersion) { $ClaudeCodeVersion = $Payload.version }

$Record = [ordered]@{
    schema_version        = "1.0"
    kind                  = "subagent"
    ts                    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    session_id            = [string]$Payload.session_id
    project_root          = $ProjectRoot
    claude_code_version   = $ClaudeCodeVersion
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
        # Detect month rollover by reading first line's ts.
        $firstMonth = $null
        if ($size -gt 0) {
            try {
                $line = Get-Content -Path $Jsonl -TotalCount 1
                if ($line) {
                    $obj = $line | ConvertFrom-Json
                    if ($obj.ts -and $obj.ts.Length -ge 7) {
                        $firstMonth = $obj.ts.Substring(0, 7)
                    }
                }
            } catch { }
        }
        $curMonth   = (Get-Date).ToUniversalTime().ToString("yyyy-MM")
        $rotateSize  = $size -gt (10 * 1024 * 1024)
        $rotateMonth = $firstMonth -and ($firstMonth -ne $curMonth)
        if ($rotateSize -or $rotateMonth) {
            if ($rotateMonth) { $tag = $firstMonth } else { $tag = (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss") }
            $archive = Join-Path $MetricsDir ("sessions.$tag.jsonl.gz")
            $fs  = [IO.File]::OpenRead($Jsonl)
            $out = [IO.File]::Create($archive)
            $gz  = New-Object IO.Compression.GZipStream($out, [IO.Compression.CompressionMode]::Compress)
            $fs.CopyTo($gz); $gz.Dispose(); $out.Dispose(); $fs.Dispose()
            Set-Content -Path $Jsonl -Value "" -Encoding UTF8 -NoNewline
            # Only timestamp-tagged archives (tag length != 7) get pruned.
            $archives = Get-ChildItem -Path $MetricsDir -Filter "sessions.*.jsonl.gz" |
                Where-Object {
                    $parts = $_.Name.Split(".")
                    $parts.Length -ge 2 -and $parts[1].Length -ne 7
                } |
                Sort-Object LastWriteTime
            if ($archives.Count -gt 4) {
                $archives | Select-Object -First ($archives.Count - 4) | Remove-Item -Force
            }
        }
    }
} catch { }

try {
    Add-Content -Path $Jsonl -Value (($Record | ConvertTo-Json -Compress -Depth 6)) -Encoding UTF8
} catch { }

exit 0
