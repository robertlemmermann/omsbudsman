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

New-Item -ItemType Directory -Force -Path (Join-Path $ClaudeHome "agents") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $ClaudeHome "hooks")  | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $ClaudeHome "memory") | Out-Null

Write-Host "Installing agents..."
Copy-Item -Path (Join-Path $SourceDir "agents\*.md") -Destination (Join-Path $ClaudeHome "agents") -Force

Write-Host "Installing hooks..."
Copy-Item -Path (Join-Path $SourceDir "hooks\*") -Destination (Join-Path $ClaudeHome "hooks") -Force

$MemoryIndex = Join-Path $ClaudeHome "memory\INDEX.md"
if (-not (Test-Path $MemoryIndex)) {
    Write-Host "Seeding memory index..."
    Copy-Item -Path (Join-Path $SourceDir "memory\INDEX.md") -Destination $MemoryIndex -Force
} else {
    Write-Host "Preserving existing memory at $($ClaudeHome)\memory\"
}

# Resolve hook command path for Windows.
$SessionStartPs1 = Join-Path $ClaudeHome "hooks\session-start.ps1"
$SessionStartCmd = "powershell.exe -ExecutionPolicy Bypass -File `"$SessionStartPs1`""

$FragmentRaw      = Get-Content -Raw -Path (Join-Path $SourceDir "settings.fragment.json")
$FragmentResolved = $FragmentRaw -replace "\{\{HOOK_CMD_SESSION_START\}\}", ($SessionStartCmd -replace '\\', '\\\\')

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

$AgentCount = (Get-ChildItem (Join-Path $ClaudeHome "agents") -File).Count
$HookCount  = (Get-ChildItem (Join-Path $ClaudeHome "hooks")  -File).Count

Write-Host ""
Write-Host "Install complete."
Write-Host "  Agents:   $AgentCount files at $($ClaudeHome)\agents"
Write-Host "  Hooks:    $HookCount files at $($ClaudeHome)\hooks"
Write-Host "  Memory:   $($ClaudeHome)\memory"
Write-Host "  Settings: $SettingsPath"
if (Test-Path $BackupDir) {
    Write-Host "  Backup:   $BackupDir"
}
Write-Host ""
Write-Host "Start a new Claude Code session to verify."
