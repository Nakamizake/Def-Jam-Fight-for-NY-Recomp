<#
.SYNOPSIS
    Records which chunk entry points the game uses, for twin chunks (dolrecomp --twin-hot).

.DESCRIPTION
    With twin chunks every chunk of recompiled code is emitted twice: a fast copy whose entry
    switch only has the entry points a training run used, and the ordinary chunk as the
    fallback for any other entry, so the list changes speed only, never behaviour.

    1. build-module.ps1 builds a bootstrap module whose hot list is empty and which counts
       every entry handed to the fallback (DOLRECOMP_TWIN_MISS_LOG). It is published to
       build/modules/<GameId>/twinboot/; the active module is left alone.
    2. bench.ps1 plays each training savestate with it, plus a cold boot to the menus. Each
       game process writes its counts when it exits.
    3. The counts are merged into build/pgo/<GameId>.hot, which build-module.ps1 then uses.

    The list holds guest addresses taken from the game, so it stays in build/ and is never
    committed. After a new list, rebuild the module and retrain PGO (train-pgo.ps1).

.EXAMPLE
    .\scripts\train-twin.ps1
    .\scripts\train-twin.ps1 -SkipBootstrapBuild
#>
[CmdletBinding()]
param(
    [string] $GameId = 'GNWE69',
    [int] $Jobs = 4,
    # Savestates to play, each for -Seconds while attacking.
    [string[]] $States = @('build\states\fight-1v1.sav', 'build\states\2v2-special.sav', 'build\states\2v2-fight.sav'),
    [int] $Seconds = 75,
    # Seconds of cold boot (intro and menus) also recorded; 0 skips it.
    [int] $BootSeconds = 90,
    # Reuses the bootstrap module from an earlier run.
    [switch] $SkipBootstrapBuild
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$pgoDir = Join-Path $repoRoot 'build\pgo'
$missDir = Join-Path $pgoDir "$GameId-twin"
$hotList = Join-Path $pgoDir "$GameId.hot"
$bootstrap = Join-Path $repoRoot "build\modules\$GameId\twinboot\g${GameId}_recomp.dll"

function Invoke-Script([string] $Name, [string[]] $Arguments) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $Name) @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Name failed ($LASTEXITCODE)." }
}

New-Item -ItemType Directory -Force $pgoDir | Out-Null
if (-not $SkipBootstrapBuild) {
    Write-Host '==> 1/3  Building the bootstrap module'
    # An empty list sends every entry to the fallback, so the miss counts are the entry counts.
    $empty = Join-Path $pgoDir 'twin-bootstrap.hot'
    '# empty: every chunk entry goes to the fallback and is counted' | Set-Content -Encoding ascii $empty
    Invoke-Script 'build-module.ps1' @('-GameId', $GameId, '-Jobs', $Jobs, '-Variant', 'twinboot', '-NoPgo', '-NoTwin',
        '-ExtraFlag', "--twin-hot,$empty,--twin-regs,ratio,--twin-cr",
        '-CFlags', '-march=native -DDOLRECOMP_TWIN_MISS_LOG', '-ModuleOption', 'MODULE_LTO=OFF')
}
if (-not (Test-Path $bootstrap)) { throw "Bootstrap module missing: $bootstrap" }

Write-Host '==> 2/3  Playing'
Remove-Item -Recurse -Force $missDir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $missDir | Out-Null
$runs = @($States | ForEach-Object { @{ Label = [IO.Path]::GetFileNameWithoutExtension($_); State = $_ } })
if ($BootSeconds -gt 0) { $runs += @{ Label = 'boot'; State = '' } }
# Unpause (the states are saved in the pause menu), then keep attacking.
$presses = @('start') + @(1..[int]($Seconds / 0.7) | ForEach-Object { @('a', 'b', 'x', 'y', 'a', 'b')[$_ % 6] })
foreach ($run in $runs) {
    Write-Host "    $($run.Label)"
    $env:DOLRECOMP_TWIN_MISS_FILE = Join-Path $missDir "$($run.Label).txt"
    try {
        $arguments = @('-Label', "twin-train-$($run.Label)", '-ScreenshotEvery', '0', '-Module', $bootstrap, '-NoFrameTimes')
        if ($run.State) {
            $arguments += @('-Seconds', $Seconds, '-LoadState', (Resolve-Path $run.State).Path,
                '-PressAfterLoad', ($presses -join ','), '-PressInterval', '0.7')
        }
        else { $arguments += @('-Seconds', $BootSeconds) }
        Invoke-Script 'bench.ps1' $arguments
    }
    finally { Remove-Item Env:DOLRECOMP_TWIN_MISS_FILE -ErrorAction SilentlyContinue }
}

Write-Host '==> 3/3  Merging the entry counts'
$hits = @{}
$files = @(Get-ChildItem $missDir -Filter *.txt)
if ($files.Count -lt $runs.Count) {
    throw "Expected $($runs.Count) count files in $missDir, found $($files.Count): a game that was killed instead of closed writes none."
}
foreach ($file in $files) {
    foreach ($line in Get-Content $file.FullName) {
        $pc, $count = $line -split '\s+'
        if ($pc -and $count) { $hits[$pc] = [uint64]$hits[$pc] + [uint64]$count }
    }
}
$hits.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name) $($_.Value)" } |
    Set-Content -Encoding ascii $hotList
Write-Host "    $($hits.Count) entry points -> $hotList"
