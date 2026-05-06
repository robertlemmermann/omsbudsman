# Installer for the Claude Code multi-agent system (Windows).
# Idempotent — re-runs are safe and create a fresh backup each time.
# Compatible with PowerShell 5.1+.

$ErrorActionPreference = "Stop"

$ClaudeHome = if ($env:CLAUDE_HOME) { $env:CLAUDE_HOME } else { Join-Path $env:USERPROFILE ".claude" }
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$SourceDir  = Join-Path $ScriptDir "claude-system"
$Timestamp  = (Get-Date -Format "yyyyMMddTHHmmssZ")
$BackupDir  = Join-Path $env:USERPROFILE ".claude.backup-$Timestamp"

if (-not (Test-Path $SourceDir)) {
    Write-Error "Source directory not found: $SourceDir"
    exit 1
}

if (Test-Path $ClaudeHome) {
    Write-Host "Backing up existing $ClaudeHome -> $BackupDir"
    Copy-Item -Path $ClaudeHome -Destination $BackupDir -Recurse -Force
}

New-Item -ItemType Directory -Force -Path (Join-Path $ClaudeHome "agents")  | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $ClaudeHome "hooks")   | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $ClaudeHome "memory")  | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $ClaudeHome "state")   | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $ClaudeHome "metrics") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $ClaudeHome "scripts") | Out-Null

Write-Host "Installing agents..."
Copy-Item -Path (Join-Path $SourceDir "agents\*.md") -Destination (Join-Path $ClaudeHome "agents") -Force

Write-Host "Installing hooks..."
Copy-Item -Path (Join-Path $SourceDir "hooks\*") -Destination (Join-Path $ClaudeHome "hooks") -Force

if (Test-Path (Join-Path $SourceDir "scripts")) {
    Write-Host "Installing scripts..."
    Copy-Item -Path (Join-Path $SourceDir "scripts\*") -Destination (Join-Path $ClaudeHome "scripts") -Force
}

$MemoryIndex = Join-Path $ClaudeHome "memory\INDEX.md"
if (-not (Test-Path $MemoryIndex)) {
    Write-Host "Seeding memory index..."
    Copy-Item -Path (Join-Path $SourceDir "memory\INDEX.md") -Destination $MemoryIndex -Force
} else {
    Write-Host "Preserving existing memory at $($ClaudeHome)\memory\"
}

# Resolve hook command paths for Windows.
$SessionStartPs1 = Join-Path $ClaudeHome "hooks\session-start.ps1"
$SessionStartCmd = "powershell.exe -ExecutionPolicy Bypass -File `"$SessionStartPs1`""

$UserPromptSubmitPs1 = Join-Path $ClaudeHome "hooks\user-prompt-submit.ps1"
$UserPromptSubmitCmd = "powershell.exe -ExecutionPolicy Bypass -File `"$UserPromptSubmitPs1`""

$PreToolUsePs1 = Join-Path $ClaudeHome "hooks\pre-tool-use.ps1"
$PreToolUseCmd = "powershell.exe -ExecutionPolicy Bypass -File `"$PreToolUsePs1`""

$SubagentStopPs1 = Join-Path $ClaudeHome "hooks\subagent-stop.ps1"
$SubagentStopCmd = "powershell.exe -ExecutionPolicy Bypass -File `"$SubagentStopPs1`""

$StopPs1 = Join-Path $ClaudeHome "hooks\stop.ps1"
$StopCmd = "powershell.exe -ExecutionPolicy Bypass -File `"$StopPs1`""

$StatuslinePs1 = Join-Path $ClaudeHome "scripts\statusline.ps1"
$StatuslineCmd = "powershell.exe -ExecutionPolicy Bypass -File `"$StatuslinePs1`""

$FragmentRaw      = Get-Content -Raw -Path (Join-Path $SourceDir "settings.fragment.json")
$FragmentResolved = $FragmentRaw `
    -replace "\{\{HOOK_CMD_SESSION_START\}\}",      ($SessionStartCmd     -replace '\\', '\\\\') `
    -replace "\{\{HOOK_CMD_USER_PROMPT_SUBMIT\}\}", ($UserPromptSubmitCmd -replace '\\', '\\\\') `
    -replace "\{\{HOOK_CMD_PRE_TOOL_USE\}\}",       ($PreToolUseCmd       -replace '\\', '\\\\') `
    -replace "\{\{HOOK_CMD_SUBAGENT_STOP\}\}",      ($SubagentStopCmd     -replace '\\', '\\\\') `
    -replace "\{\{HOOK_CMD_STOP\}\}",               ($StopCmd             -replace '\\', '\\\\') `
    -replace "\{\{STATUSLINE_CMD\}\}",              ($StatuslineCmd       -replace '\\', '\\\\')

Write-Host "Merging settings..."
$Settings = $null
$SettingsPath = Join-Path $ClaudeHome "settings.json"
if ((Test-Path $SettingsPath) -and ((Get-Item $SettingsPath).Length -gt 0)) {
    try {
        $Settings = Get-Content -Raw -Path $SettingsPath | ConvertFrom-Json
    } catch {
        Write-Error "Existing settings.json is invalid JSON. Fix or remove it, then re-run."
        exit 2
    }
} else {
    $Settings = New-Object PSObject
}

$Fragment = $FragmentResolved | ConvertFrom-Json

function Merge-Object($a, $b) {
    foreach ($prop in $b.PSObject.Properties) {
        $name = $prop.Name
        $bVal = $prop.Value
        if ($a.PSObject.Properties[$name]) {
            $aVal = $a.$name
            if ($aVal -is [PSCustomObject] -and $bVal -is [PSCustomObject]) {
                Merge-Object $aVal $bVal
            } elseif ($aVal -is [System.Collections.IList] -and $bVal -is [System.Collections.IList]) {
                $a.$name = @($aVal) + @($bVal)
            } else {
                $a.$name = $bVal
            }
        } else {
            Add-Member -InputObject $a -MemberType NoteProperty -Name $name -Value $bVal -Force
        }
    }
}

Merge-Object $Settings $Fragment

$Settings | ConvertTo-Json -Depth 20 | Set-Content -Path $SettingsPath -Encoding UTF8

$AgentCount  = (Get-ChildItem (Join-Path $ClaudeHome "agents")  -File).Count
$HookCount   = (Get-ChildItem (Join-Path $ClaudeHome "hooks")   -File).Count
$ScriptCount = 0
if (Test-Path (Join-Path $ClaudeHome "scripts")) {
    $ScriptCount = (Get-ChildItem (Join-Path $ClaudeHome "scripts") -File).Count
}

Write-Host ""
Write-Host "Install complete."
Write-Host "  Agents:   $AgentCount files at $($ClaudeHome)\agents"
Write-Host "  Hooks:    $HookCount files at $($ClaudeHome)\hooks"
Write-Host "  Scripts:  $ScriptCount files at $($ClaudeHome)\scripts"
Write-Host "  Memory:   $($ClaudeHome)\memory"
Write-Host "  Metrics:  $($ClaudeHome)\metrics"
Write-Host "  Settings: $SettingsPath"
if (Test-Path $BackupDir) {
    Write-Host "  Backup:   $BackupDir"
}
Write-Host ""
Write-Host "Start a new Claude Code session to verify."
Write-Host "Run $($ClaudeHome)\scripts\metrics.ps1 after a few sessions for cost/perf reports."
Write-Host "Set `$env:CLAUDE_MULTIAGENT_NO_METRICS=1 to disable telemetry."
