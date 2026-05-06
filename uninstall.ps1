# Uninstaller — removes our agents/hooks/settings entries, preserves memory.
# Always backs up the current state before changing anything.

$ErrorActionPreference = "Stop"

$ClaudeHome      = if ($env:CLAUDE_HOME) { $env:CLAUDE_HOME } else { Join-Path $env:USERPROFILE ".claude" }
$ScriptDir       = Split-Path -Parent $MyInvocation.MyCommand.Definition
$SourceDir       = Join-Path $ScriptDir "claude-system"
$Timestamp       = (Get-Date -Format "yyyyMMddTHHmmssZ")
$PreuninstallDir = Join-Path $env:USERPROFILE ".claude.preuninstall-$Timestamp"

if (-not (Test-Path $ClaudeHome)) {
    Write-Host "Nothing to uninstall - $ClaudeHome does not exist."
    exit 0
}

if (-not (Test-Path $SourceDir)) {
    Write-Error "Source directory not found: $SourceDir. Run from the repository root."
    exit 1
}

Write-Host "Backing up current state to $PreuninstallDir"
Copy-Item -Path $ClaudeHome -Destination $PreuninstallDir -Recurse -Force

Write-Host "Removing our agents..."
Get-ChildItem (Join-Path $SourceDir "agents") -Filter "*.md" | ForEach-Object {
    $target = Join-Path $ClaudeHome "agents\$($_.Name)"
    if (Test-Path $target) { Remove-Item -Force $target }
}

Write-Host "Removing our hooks..."
Get-ChildItem (Join-Path $SourceDir "hooks") | ForEach-Object {
    $target = Join-Path $ClaudeHome "hooks\$($_.Name)"
    if (Test-Path $target) { Remove-Item -Force $target }
}

if (Test-Path (Join-Path $SourceDir "scripts")) {
    Write-Host "Removing our scripts..."
    Get-ChildItem (Join-Path $SourceDir "scripts") | ForEach-Object {
        $target = Join-Path $ClaudeHome "scripts\$($_.Name)"
        if (Test-Path $target) { Remove-Item -Force $target }
    }
}

$SettingsPath = Join-Path $ClaudeHome "settings.json"
if (Test-Path $SettingsPath) {
    Write-Host "Cleaning settings entries..."
    $HooksDir = Join-Path $ClaudeHome "hooks"
    try {
        $Settings = Get-Content -Raw -Path $SettingsPath | ConvertFrom-Json
    } catch {
        Write-Warning "settings.json is not valid JSON; leaving it untouched."
        $Settings = $null
    }
    if ($null -ne $Settings -and $Settings.PSObject.Properties["hooks"]) {
        $hooks = $Settings.hooks
        $eventNames = @($hooks.PSObject.Properties.Name)
        foreach ($event in $eventNames) {
            $groups = $hooks.$event
            if ($groups -isnot [System.Collections.IList]) { continue }
            $newGroups = @()
            foreach ($g in $groups) {
                $inner = @()
                if ($g.PSObject.Properties["hooks"] -and $g.hooks -is [System.Collections.IList]) {
                    $inner = $g.hooks | Where-Object { $_.command -notlike "*$HooksDir*" }
                }
                if ($inner.Count -gt 0) {
                    $g.hooks = @($inner)
                    $newGroups += $g
                }
            }
            if ($newGroups.Count -gt 0) {
                $hooks.$event = @($newGroups)
            } else {
                $hooks.PSObject.Properties.Remove($event)
            }
        }
        if (@($hooks.PSObject.Properties).Count -eq 0) {
            $Settings.PSObject.Properties.Remove("hooks")
        }
    }
    if ($null -ne $Settings -and $Settings.PSObject.Properties["statusLine"]) {
        $ScriptsDir = Join-Path $ClaudeHome "scripts"
        $cmd = [string]$Settings.statusLine.command
        if ($cmd -like "*$ScriptsDir*") {
            $Settings.PSObject.Properties.Remove("statusLine")
        }
    }
    if ($null -ne $Settings) {
        $Settings | ConvertTo-Json -Depth 20 | Set-Content -Path $SettingsPath -Encoding UTF8
    }
}

Write-Host "Memory preserved at $($ClaudeHome)\memory\"
if (Test-Path (Join-Path $ClaudeHome "metrics")) {
    Write-Host "Metrics preserved at $($ClaudeHome)\metrics\"
}
Write-Host ""
Write-Host "Uninstall complete."
Write-Host "  Backup: $PreuninstallDir"
