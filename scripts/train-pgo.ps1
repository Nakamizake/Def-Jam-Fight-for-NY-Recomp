<#
.SYNOPSIS
    Trains a profile-guided optimisation (PGO) profile for the game module and rebuilds the
    module with it.

.DESCRIPTION
    1. build-module.ps1 -PgoInstrumentDir builds a module that counts how often every branch
       and function of the recompiled code runs.
    2. bench.ps1 plays each training savestate with that module, pressing attack buttons. The
       counts are written to build/pgo/<GameId>-raw/*.profraw when the game exits.
    3. llvm-profdata merges them into build/pgo/<GameId>.profdata.
    4. build-module.ps1 builds the normal module with the profile (it picks it up by default).

    Train on fights only. RingOut measured that menus carry almost none of a session's work
    and that broader training sets made the result slower: the weight goes to code the
    player does not run.

    The profile only fits the generated code and the Clang that built it: retrain after a
    change to config/recomp/<GameId>.flags or .regions, to the twin hot list (train-twin.ps1),
    to dolrecomp or to the toolchain.

.EXAMPLE
    .\scripts\train-pgo.ps1
    .\scripts\train-pgo.ps1 -SkipInstrumentedBuild -Seconds 90
#>
[CmdletBinding()]
param(
    [string] $GameId = 'GNWE69',
    # Parallel compiles for both module builds.
    [int] $Jobs = 4,
    # Fight savestates to train on, each played for -Seconds.
    [string[]] $States = @('build\states\fight-1v1.sav', 'build\states\2v2-special.sav'),
    [int] $Seconds = 75,
    # Reuses the instrumented module from an earlier run.
    [switch] $SkipInstrumentedBuild,
    # Stops after merging the profile, without rebuilding the module.
    [switch] $SkipFinalBuild
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$pgoDir = Join-Path $repoRoot 'build\pgo'
$rawDir = Join-Path $pgoDir "$GameId-raw"
$profilePath = Join-Path $pgoDir "$GameId.profdata"
$instrumented = Join-Path $repoRoot "build\modules\$GameId\pgo-instrumented\g${GameId}_recomp.dll"
$profdata = Join-Path $repoRoot 'tools\llvm-mingw\bin\llvm-profdata.exe'
if (-not (Test-Path $profdata)) { throw 'llvm-profdata not found in tools\llvm-mingw (see docs/external-footprint.md).' }

function Invoke-Script([string] $Name, [string[]] $Arguments) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $Name) @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Name failed ($LASTEXITCODE)." }
}

if (-not $SkipInstrumentedBuild) {
    Write-Host '==> 1/4  Building the instrumented module'
    Invoke-Script 'build-module.ps1' @('-GameId', $GameId, '-Jobs', $Jobs, '-PgoInstrumentDir', $rawDir)
}
if (-not (Test-Path $instrumented)) { throw "Instrumented module missing: $instrumented" }

Write-Host '==> 2/4  Playing the training fights'
Remove-Item -Recurse -Force $rawDir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $rawDir | Out-Null
# Unpause (the states are saved in the pause menu), then keep attacking.
$presses = @('start') + @(1..[int]($Seconds / 0.7) | ForEach-Object { @('a', 'b', 'x', 'y', 'a', 'b')[$_ % 6] })
foreach ($state in $States) {
    $label = 'pgo-train-' + [IO.Path]::GetFileNameWithoutExtension($state)
    Write-Host "    $state"
    # The instrumented module reads LLVM_PROFILE_FILE (inherited through bench.ps1 and
    # run.ps1); %p keeps one file per game process.
    $env:LLVM_PROFILE_FILE = Join-Path $rawDir '%p.profraw'
    try {
        Invoke-Script 'bench.ps1' @('-Seconds', $Seconds, '-Label', $label, '-ScreenshotEvery', '0',
            '-LoadState', (Resolve-Path $state).Path, '-PressAfterLoad', ($presses -join ','),
            '-PressInterval', '0.7', '-Module', $instrumented, '-NoFrameTimes')
    }
    finally { Remove-Item Env:LLVM_PROFILE_FILE -ErrorAction SilentlyContinue }
}
$raw = @(Get-ChildItem $rawDir -Filter *.profraw -ErrorAction SilentlyContinue)
if ($raw.Count -lt $States.Count) {
    throw "Expected $($States.Count) .profraw files in $rawDir, found $($raw.Count): a game that was killed instead of closed writes none."
}

Write-Host '==> 3/4  Merging the counts'
& $profdata merge "-output=$profilePath" @($raw | ForEach-Object FullName)
if ($LASTEXITCODE -ne 0) { throw "llvm-profdata merge failed ($LASTEXITCODE)." }
Write-Host "    $profilePath"

if (-not $SkipFinalBuild) {
    Write-Host '==> 4/4  Building the module with the profile'
    Invoke-Script 'build-module.ps1' @('-GameId', $GameId, '-Jobs', $Jobs, '-PgoProfile', $profilePath)
}
