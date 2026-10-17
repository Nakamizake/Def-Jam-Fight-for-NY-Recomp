<#
.SYNOPSIS
    Runs the recompiled game with the ModernGekko runtime.

.DESCRIPTION
    Uses the module most recently built by scripts/build-module.ps1. All runtime data
    (config, memory cards, dumps) is kept in userdata/ inside the repository instead of
    %LOCALAPPDATA%.

.EXAMPLE
    .\scripts\run.ps1
    .\scripts\run.ps1 -Graphics Vulkan
#>
[CmdletBinding()]
param(
    [string] $GameId = 'GNWE69',
    [ValidateSet('', 'Vulkan', 'D3D', 'D3D12', 'OGL')]
    [string] $Graphics = '',
    # Enables ModernGekko's file-based automation (pad input, status.txt); used by bench.ps1.
    [string] $AutomationDir = '',
    # Boots straight into a savestate (e.g. one saved mid-fight for benchmarking).
    [string] $LoadState = '',
    # Uses the runtime built by `build-tools.ps1 -Profiling` (same speed, with a PDB).
    [switch] $Profiling,
    # Game module DLL to load instead of the one in active-module.txt (e.g. a relink with a PDB).
    [string] $Module = '',
    # Runtime user directory (config, memory cards, caches); bench.ps1 points this at a copy.
    [string] $UserDir = '',
    [string[]] $ExtraArgs = @()
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

$runtimeBuild = if ($Profiling) { 'runtime-prof' } else { 'runtime' }
$runner = Join-Path $repoRoot "build\$runtimeBuild\moderngekko-run.exe"
$gameRoot = Join-Path $repoRoot "extracted\$GameId"
$moduleRoot = Join-Path $repoRoot "build\modules\$GameId"
$userDir = if ($UserDir) { $UserDir } else { Join-Path $repoRoot 'userdata' }

if (-not (Test-Path $runner)) { throw "Runtime not built: $runner. Run scripts\build-tools.ps1 first." }
if (-not (Test-Path $gameRoot)) { throw "Game not extracted: $gameRoot." }

# moderngekko-port records the module it built last in active-module.txt (path relative to the repo root).
$activeModuleFile = Join-Path $moduleRoot 'active-module.txt'
if (-not (Test-Path $activeModuleFile)) { throw "No module in $moduleRoot. Run scripts\build-module.ps1 first." }
$modulePath = if ($Module) { $Module } else { (Get-Content $activeModuleFile -TotalCount 1).Trim() }
if (-not [IO.Path]::IsPathRooted($modulePath)) { $modulePath = Join-Path $repoRoot $modulePath }
$moduleFile = Get-Item $modulePath

New-Item -ItemType Directory -Force $userDir | Out-Null

# Per-game settings tracked in the repo (idle loop, threading, ...).
$gameSettings = Join-Path $repoRoot "config\GameSettings\$GameId.ini"
if (Test-Path $gameSettings) {
    $userGameSettings = Join-Path $userDir 'GameSettings'
    New-Item -ItemType Directory -Force $userGameSettings | Out-Null
    Copy-Item $gameSettings $userGameSettings -Force
}

# Player-tunable defaults: only keys missing from Dolphin.ini are added, so whatever the
# player picks in the in-game menu is kept on later runs.
function Add-MissingIniKeys([string] $DefaultsPath, [string] $TargetPath) {
    $lines = [Collections.Generic.List[string]]::new()
    if (Test-Path $TargetPath) { $lines.AddRange([string[]](Get-Content $TargetPath)) }
    $section = ''
    $changed = $false
    foreach ($raw in Get-Content $DefaultsPath) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        if ($line -match '^\[(.+)\]$') { $section = $Matches[1]; continue }
        $key = ($line -split '=', 2)[0].Trim()

        # Locate the section in the target and look for the key inside it.
        $sectionStart = -1
        $sectionEnd = $lines.Count
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i].Trim() -match '^\[(.+)\]$') {
                if ($sectionStart -ge 0) { $sectionEnd = $i; break }
                if ($Matches[1] -eq $section) { $sectionStart = $i }
            }
        }
        if ($sectionStart -lt 0) {
            $lines.Add("[$section]")
            $lines.Add($line)
            $changed = $true
            continue
        }
        $present = $false
        for ($i = $sectionStart + 1; $i -lt $sectionEnd; $i++) {
            if (($lines[$i] -split '=', 2)[0].Trim() -eq $key) { $present = $true; break }
        }
        if (-not $present) {
            $lines.Insert($sectionEnd, $line)
            $changed = $true
        }
    }
    if ($changed) {
        New-Item -ItemType Directory -Force (Split-Path -Parent $TargetPath) | Out-Null
        [IO.File]::WriteAllLines($TargetPath, $lines, [Text.UTF8Encoding]::new($false))
    }
}
$defaultSettings = Join-Path $repoRoot 'config\Dolphin.defaults.ini'
if (Test-Path $defaultSettings) {
    Add-MissingIniKeys $defaultSettings (Join-Path $userDir 'Config\Dolphin.ini')
}

# Default controller profile (PS2 layout), copied whole and only once: a profile is one
# coherent set of bindings, so merging keys into a rebound one would scramble it.
$defaultPad = Join-Path $repoRoot 'config\Controllers\GCPadNew.defaults.ini'
$userPad = Join-Path $userDir 'Config\GCPadNew.ini'
if ((Test-Path $defaultPad) -and -not (Test-Path $userPad)) {
    New-Item -ItemType Directory -Force (Split-Path -Parent $userPad) | Out-Null
    Copy-Item $defaultPad $userPad
}

$arguments = @('--game', $gameRoot, '--module', $moduleFile.FullName, '--user-dir', $userDir)
if ($Graphics) { $arguments += @('--graphics', $Graphics) }
if ($AutomationDir) { $arguments += @('--automation-dir', $AutomationDir) }
if ($LoadState) { $arguments += @('--load-state', (Resolve-Path $LoadState).Path) }
$arguments += $ExtraArgs

Write-Host "Module: $($moduleFile.FullName)"
& $runner @arguments
exit $LASTEXITCODE
