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
    # Extracted game directory; defaults to extracted/<GameId> in the repository (e.g. a copy
    # on a faster disk).
    [string] $GameRoot = '',
    [string[]] $ExtraArgs = @()
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

$runtimeBuild = if ($Profiling) { 'runtime-prof' } else { 'runtime' }
$runner = Join-Path $repoRoot "build\$runtimeBuild\moderngekko-run.exe"
$gameRoot = if ($GameRoot) { $GameRoot } else { Join-Path $repoRoot "extracted\$GameId" }
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

Import-Module (Join-Path $PSScriptRoot 'GameBuild.psm1') -Force
Initialize-UserDirectory -UserDir $userDir -ConfigDir (Join-Path $repoRoot 'config') -GameId $GameId

# The port's fixes (<game>/fixes, see tools-src/modding/port_fixes.py), rebuilt when missing or
# older than the tools that make them.
$fixes = Join-Path $gameRoot 'fixes'
$fixTools = Get-ChildItem (Join-Path $repoRoot 'tools-src\modding') -Filter *.py
if (-not (Test-Path $fixes) -or
    ($fixTools | Where-Object LastWriteTime -gt (Get-Item $fixes).LastWriteTime)) {
    & (Join-Path $repoRoot 'tools\llvm-mingw\python\bin\python.exe') -I `
        (Join-Path $repoRoot 'tools-src\modding\port_fixes.py') --game $gameRoot
    if ($LASTEXITCODE -ne 0) { Write-Warning "The port's fixes could not be built; running without them." }
}

$arguments = @('--game', $gameRoot, '--module', $moduleFile.FullName, '--user-dir', $userDir,
    '--title', 'Def Jam: Fight for NY')
if ($Graphics) { $arguments += @('--graphics', $Graphics) }
if ($AutomationDir) { $arguments += @('--automation-dir', $AutomationDir) }
if ($LoadState) { $arguments += @('--load-state', (Resolve-Path $LoadState).Path) }
$arguments += $ExtraArgs

Write-Host "Module: $($moduleFile.FullName)"
& $runner @arguments
exit $LASTEXITCODE
