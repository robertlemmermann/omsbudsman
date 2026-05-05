# Phase 6: report metrics from $env:CLAUDE_HOME\metrics\sessions.jsonl.
#
# Usage:
#   metrics.ps1                       # last 7 days summary
#   metrics.ps1 -Agent <name>         # per-agent breakdown
#   metrics.ps1 -Session <id>         # one session's flow
#   metrics.ps1 -Baseline             # write/update metrics\BASELINE.md
#   metrics.ps1 -Json                 # raw JSON of the summary
#   metrics.ps1 -Days <N>             # restrict window to N days (default 7)

param(
    [string]$Agent,
    [string]$Session,
    [switch]$Baseline,
    [switch]$Json,
    [int]$Days = 7
)

$ErrorActionPreference = "Stop"

$GlobalRoot = if ($env:LIBRARIAN_GLOBAL_ROOT) { $env:LIBRARIAN_GLOBAL_ROOT }
              elseif ($env:CLAUDE_HOME)      { $env:CLAUDE_HOME }
              else                           { Join-Path $env:USERPROFILE ".claude" }
$Jsonl    = Join-Path $GlobalRoot "metrics\sessions.jsonl"
$BaselineMd = Join-Path $GlobalRoot "metrics\BASELINE.md"

if (-not (Test-Path $Jsonl)) {
    Write-Host "No metrics yet at $Jsonl"
    exit 0
}

# Pricing per 1M tokens (input / output). Update when Anthropic changes them.
$Pricing = @{
    "claude-opus-4-7"            = @(15.00, 75.00)
    "claude-opus-4-6"            = @(15.00, 75.00)
    "claude-sonnet-4-6"          = @( 3.00, 15.00)
    "claude-haiku-4-5"           = @( 1.00,  5.00)
    "claude-haiku-4-5-20251001"  = @( 1.00,  5.00)
}
$DefaultPrice = @(3.00, 15.00)

function Cost-Of { param($model, $inT, $outT)
    $rates = if ($Pricing.ContainsKey($model)) { $Pricing[$model] } else { $DefaultPrice }
    return ($inT / 1e6) * $rates[0] + ($outT / 1e6) * $rates[1]
}

$Cutoff = (Get-Date).ToUniversalTime().AddDays(-$Days)

$All = @()
Get-Content -Path $Jsonl | ForEach-Object {
    if ([string]::IsNullOrWhiteSpace($_)) { return }
    try { $All += ($_ | ConvertFrom-Json) } catch { }
}

$Subagents = $All | Where-Object { $_.kind -eq "subagent" }
$Sessions  = $All | Where-Object { $_.kind -eq "session"  }

if (-not $Baseline -and -not $Session) {
    $Subagents = $Subagents | Where-Object {
        $ts = $null; try { $ts = [datetime]::ParseExact($_.ts, "yyyy-MM-ddTHH:mm:ssZ", $null) } catch { }
        $null -ne $ts -and $ts -ge $Cutoff
    }
    $Sessions = $Sessions | Where-Object {
        $ts = $null; try { $ts = [datetime]::ParseExact($_.ts, "yyyy-MM-ddTHH:mm:ssZ", $null) } catch { }
        $null -ne $ts -and $ts -ge $Cutoff
    }
}

function Stat-Of { param($xs)
    if (-not $xs -or $xs.Count -eq 0) { return $null }
    $sorted = $xs | Sort-Object
    $idx95 = [math]::Min($sorted.Count - 1, [int][math]::Round($sorted.Count * 0.95) - 1)
    if ($idx95 -lt 0) { $idx95 = 0 }
    return [PSCustomObject]@{
        n    = $xs.Count
        mean = [math]::Round(($xs | Measure-Object -Average).Average, 1)
        p50  = $sorted[[int]($sorted.Count / 2)]
        p95  = $sorted[$idx95]
    }
}

function Summarize-Agent { param([string]$name)
    $rs = $Subagents | Where-Object { $_.agent -eq $name }
    if (-not $rs -or $rs.Count -eq 0) { return $null }
    $inp = @($rs | ForEach-Object { $_.input_tokens } | Where-Object { $_ -is [int] -or $_ -is [long] -or $_ -is [double] })
    $out = @($rs | ForEach-Object { $_.output_tokens } | Where-Object { $_ -is [int] -or $_ -is [long] -or $_ -is [double] })
    $cr  = @($rs | ForEach-Object { if ($null -eq $_.cache_read_tokens) { 0 } else { $_.cache_read_tokens } })
    $blocked = ($rs | Where-Object { $_.blocked }).Count
    $sumIn = ($inp | Measure-Object -Sum).Sum
    $sumCR = ($cr  | Measure-Object -Sum).Sum
    $cacheRate = if ($sumIn -and $sumIn -gt 0) { [math]::Round($sumCR / $sumIn, 3) } else { $null }
    $totalCost = 0.0
    foreach ($r in $rs) {
        $totalCost += Cost-Of $r.model ($r.input_tokens  | ForEach-Object { if ($null -eq $_) { 0 } else { $_ } }) ($r.output_tokens | ForEach-Object { if ($null -eq $_) { 0 } else { $_ } })
    }
    return [PSCustomObject]@{
        agent          = $name
        calls          = $rs.Count
        input          = (Stat-Of $inp)
        output         = (Stat-Of $out)
        cache_hit_rate = $cacheRate
        blocked_rate   = [math]::Round($blocked / $rs.Count, 3)
        total_cost_usd = [math]::Round($totalCost, 4)
    }
}

function Summarize-Overall {
    $agents = ($Subagents | ForEach-Object { $_.agent } | Where-Object { $_ } | Sort-Object -Unique)
    $byAgent = @()
    foreach ($a in $agents) { $r = Summarize-Agent $a; if ($r) { $byAgent += $r } }

    $byClass = @{}
    foreach ($s in $Sessions) {
        $c = if ($s.task_class) { $s.task_class } else { "other" }
        if (-not $byClass.ContainsKey($c)) { $byClass[$c] = @() }
        $byClass[$c] += $s
    }
    $classSummary = [ordered]@{}
    foreach ($c in ($byClass.Keys | Sort-Object)) {
        $ss = $byClass[$c]
        $inT  = @($ss | ForEach-Object { $_.total_input_tokens  } | Where-Object { $_ -is [int] -or $_ -is [long] -or $_ -is [double] })
        $outT = @($ss | ForEach-Object { $_.total_output_tokens } | Where-Object { $_ -is [int] -or $_ -is [long] -or $_ -is [double] })
        $classSummary[$c] = [PSCustomObject]@{
            sessions     = $ss.Count
            mean_input   = if ($inT.Count)  { [math]::Round(($inT  | Measure-Object -Average).Average, 1) } else { $null }
            mean_output  = if ($outT.Count) { [math]::Round(($outT | Measure-Object -Average).Average, 1) } else { $null }
        }
    }

    $qa = @($Sessions | ForEach-Object { $_.qa_pass_rate } | Where-Object { $_ -is [int] -or $_ -is [long] -or $_ -is [double] })
    $auditorVerdicts = @($Sessions | ForEach-Object { $_.auditor_verdict } | Where-Object { $_ })
    $auditorDist = [ordered]@{}
    foreach ($v in ($auditorVerdicts | Sort-Object -Unique)) { $auditorDist[$v] = ($auditorVerdicts | Where-Object { $_ -eq $v }).Count }

    $retroTriggered = ($Sessions | Where-Object { $_.retro_triggered }).Count
    $mistakesTotal  = ($Sessions | ForEach-Object { if ($_.mistakes_recorded) { $_.mistakes_recorded } else { 0 } } | Measure-Object -Sum).Sum
    $retroFp        = $null
    if ($retroTriggered -gt 0) {
        $retroFp = [math]::Round(1 - ($mistakesTotal / $retroTriggered), 3)
    }

    return [PSCustomObject]@{
        window_days                 = $Days
        session_count               = $Sessions.Count
        subagent_calls              = $Subagents.Count
        by_agent                    = $byAgent
        by_task_class               = $classSummary
        qa_mean_pass_rate           = if ($qa.Count) { [math]::Round(($qa | Measure-Object -Average).Average, 3) } else { $null }
        auditor_distribution        = $auditorDist
        retro_triggered             = $retroTriggered
        mistakes_recorded           = $mistakesTotal
        retro_false_positive_rate   = $retroFp
    }
}

function Render-Text { param($summary)
    $lines = @()
    $lines += "=== Multi-agent metrics - last $($summary.window_days) days ==="
    $lines += "Sessions: $($summary.session_count)    Subagent calls: $($summary.subagent_calls)"
    if ($null -ne $summary.qa_mean_pass_rate) { $lines += "QA mean pass rate: $('{0:P0}' -f $summary.qa_mean_pass_rate)" }
    if ($summary.auditor_distribution.Count -gt 0) {
        $ad = ($summary.auditor_distribution.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "  "
        $lines += "Auditor verdicts: $ad"
    }
    if ($summary.retro_triggered -gt 0) {
        $fp = if ($null -ne $summary.retro_false_positive_rate) { '{0:P0}' -f $summary.retro_false_positive_rate } else { "n/a" }
        $lines += "Retro: triggered $($summary.retro_triggered), mistakes recorded $($summary.mistakes_recorded), false-positive rate $fp"
    }
    $lines += ""
    $lines += "Per agent (calls, mean output tokens, cache hit, blocked %, `$):"
    foreach ($a in $summary.by_agent) {
        $om = if ($a.output) { $a.output.mean } else { "-" }
        $ch = if ($null -ne $a.cache_hit_rate) { '{0:P0}' -f $a.cache_hit_rate } else { "n/a" }
        $lines += ("  {0,-22} n={1,3}  out_mean={2,6}  cache={3,4}  blocked={4:P0}  `${5:N4}" -f $a.agent, $a.calls, $om, $ch, $a.blocked_rate, $a.total_cost_usd)
    }
    $lines += ""
    $lines += "Per task class (sessions, mean input, mean output):"
    foreach ($c in $summary.by_task_class.Keys) {
        $v = $summary.by_task_class[$c]
        $lines += ("  {0,-10} n={1,3}  input_mean={2}  output_mean={3}" -f $c, $v.sessions, $v.mean_input, $v.mean_output)
    }
    return ($lines -join "`n")
}

function Render-Session { param([string]$sid)
    $rs   = $Subagents | Where-Object { $_.session_id -eq $sid }
    $sess = $Sessions  | Where-Object { $_.session_id -eq $sid }
    if (-not $rs -and -not $sess) { return "No records for session $sid" }
    $lines = @("=== Session $sid ===")
    if ($sess) {
        $s = $sess[-1]
        $lines += "task_class=$($s.task_class)  subagents=$($s.subagent_count)"
        $lines += "input_tokens=$($s.total_input_tokens)  output_tokens=$($s.total_output_tokens)  cache_hit=$($s.cache_hit_rate)"
        $lines += "auditor=$($s.auditor_verdict)  qa_pass_rate=$($s.qa_pass_rate)  retro=$($s.retro_triggered)"
    }
    $lines += "Subagent flow:"
    foreach ($r in $rs) {
        $lines += ("  {0} {1,-22} model={2}  in={3}  out={4}  blocked={5}" -f $r.ts, $r.agent, $r.model, $r.input_tokens, $r.output_tokens, $r.blocked)
    }
    return ($lines -join "`n")
}

if ($Session) {
    Render-Session $Session
    exit 0
}

if ($Agent) {
    $a = Summarize-Agent $Agent
    if (-not $a) { Write-Host "no calls for agent $Agent"; exit 0 }
    $a | ConvertTo-Json -Depth 6
    exit 0
}

$summary = Summarize-Overall

if ($Json) {
    $summary | ConvertTo-Json -Depth 8
    exit 0
}

if ($Baseline) {
    $text = Render-Text $summary
    $now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ssZ")
    $body = @"
# Baseline metrics

> Generated: $now from $($summary.session_count) sessions / $($summary.subagent_calls) subagent calls over the last $Days days.

Reading guide:
- ``out_mean`` is the average output-token count per call. Tighten the agent's cap if it drifts up.
- ``cache`` is the cache-hit rate on input tokens. Low rates mean the system prompt is varying.
- ``blocked`` is the rate of ``BLOCKED`` returns. Very high → pre-flight is too strict, or the planner is dispatching wrong.
- ``$`` is best-effort using pricing constants embedded in metrics.ps1 — update them when Anthropic changes prices.

``````
$text
``````
"@
    New-Item -ItemType Directory -Force -Path (Split-Path $BaselineMd) | Out-Null
    Set-Content -Path $BaselineMd -Value $body -Encoding UTF8
    Write-Host "Wrote $BaselineMd"
    Write-Host ""
    Write-Host $text
    exit 0
}

Render-Text $summary
