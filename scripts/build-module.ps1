<#
.SYNOPSIS
    Recompiles the game's main.dol and builds the native game module with Clang.

.DESCRIPTION
    1. dolrecomp (built by build-tools.ps1) translates main.dol to C, using the flags in
       config/recomp/<GameId>.flags.
    2. The C is compiled into g<GameId>_recomp.dll with the portable llvm-mingw Clang in
       tools/llvm-mingw, through RingOut's module CMake project. RingOut's generated code
       needs Clang (preserve_none, vector extensions, __builtin_choose_expr); MSVC cannot
       build it.
    3. The DLL is copied to build/modules/<GameId>/ and recorded in active-module.txt,
       which run.ps1 and bench.ps1 read.

    Work files go to build/module-work/<GameId>.

    Profile-guided optimisation: when build/pgo/<GameId>.profdata exists (made by
    scripts/train-pgo.ps1), the module is compiled with it. RingOut measured 10-14% less CPU
    time per match with a profile trained on the same machine and compiler.

    Native regions (config/recomp/<GameId>.regions) and twin chunks (build/pgo/<GameId>.hot,
    made by scripts/train-twin.ps1) are used when their lists exist; -NoRegions and -NoTwin
    turn them off. Both change the generated code, so retrain the PGO profile after either.

.EXAMPLE
    .\scripts\build-module.ps1
    .\scripts\build-module.ps1 -Jobs 6
    .\scripts\build-module.ps1 -NoPgo
    .\scripts\build-module.ps1 -Variant plain -NoPgo -NoTwin -NoRegions
#>
[CmdletBinding()]
param(
    [string] $GameId = 'GNWE69',
    # Parallel compiles. Keep RAM in mind: large chunks take over 1 GB each.
    [int] $Jobs = 8,
    # Builds a side variant (for bisecting codegen flags) into build/module-work/<id>-<Variant>
    # and build/modules/<id>/<Variant>/, leaving active-module.txt alone.
    [string] $Variant = '',
    # Recompiler flags from the flags file to leave out of this build.
    [string[]] $ExcludeFlag = @(),
    # Recompiler flags added after the flags file, for experiments (comma lists accepted;
    # give file arguments as absolute paths).
    [string[]] $ExtraFlag = @(),
    # Module CMake option overrides, e.g. MODULE_PSQ_FAST=OFF (comma lists accepted).
    [string[]] $ModuleOption = @(),
    # C flags for the generated code.
    [string] $CFlags = '-march=native',
    # Builds the module instrumented for profile-guided optimisation instead: a run of it
    # writes .profraw counts into this directory (see train-pgo.ps1). Published to
    # build/modules/<GameId>/pgo-instrumented/; active-module.txt is left alone.
    [string] $PgoInstrumentDir = '',
    # Profile to compile with; defaults to build/pgo/<GameId>.profdata when that exists.
    [string] $PgoProfile = '',
    # Builds without a profile even when one exists.
    [switch] $NoPgo,
    # Builds without twin chunks even when build/pgo/<GameId>.hot exists.
    [switch] $NoTwin,
    # Builds without native regions even when config/recomp/<GameId>.regions exists.
    [switch] $NoRegions
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'GameBuild.psm1') -Force

$repoRoot = Split-Path -Parent $PSScriptRoot
$dolrecomp = Join-Path $repoRoot 'build\runtime\dolrecomp-build\dolrecomp.exe'
$clang = Join-Path $repoRoot 'tools\llvm-mingw\bin\clang.exe'
$moduleSource = Join-Path $repoRoot 'lib\RingOut\dist\RingOut-1.0-dist\module-src'
$dol = Join-Path $repoRoot "extracted\$GameId\sys\main.dol"
$variantSuffix = if ($Variant) { "-$Variant" } else { '' }
$work = Join-Path $repoRoot "build\module-work\$GameId$variantSuffix"
$moduleBuild = Join-Path $work 'build'
$moduleDir = Join-Path $repoRoot "build\modules\$GameId"
if ($Variant) { $moduleDir = Join-Path $moduleDir $Variant }
if ($PgoInstrumentDir) {
    # Same generated tree as the normal build, so the counts match the code they are later
    # applied to; only the CMake build directory and the published copy differ.
    $moduleBuild = Join-Path $work 'build-pgo-instrumented'
    $moduleDir = Join-Path $moduleDir 'pgo-instrumented'
    $NoPgo = $true
}
if (-not $PgoProfile) { $PgoProfile = Join-Path $repoRoot "build\pgo\$GameId.profdata" }
if ($NoPgo) { $PgoProfile = '' }

function Find-Executable([string] $Name, [string[]] $Candidates) {
    foreach ($candidate in $Candidates) { if ($candidate -and (Test-Path $candidate)) { return $candidate } }
    $onPath = Get-Command $Name -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    throw "$Name not found."
}

if (-not (Test-Path $dolrecomp)) {
    $dolrecomp = Get-ChildItem (Join-Path $repoRoot 'build\runtime') -Recurse -Filter dolrecomp.exe -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $dolrecomp) { throw 'dolrecomp.exe not found. Run scripts\build-tools.ps1 first.' }
}
if (-not (Test-Path $clang)) { throw 'Clang not found in tools\llvm-mingw (see docs/external-footprint.md).' }
if (-not (Test-Path $dol)) { throw "Game not extracted: $dol" }

$vsRoot = 'C:\Program Files\Microsoft Visual Studio\2022\Community'
$toolchain = @{
    Clang  = $clang
    CMake  = Find-Executable 'cmake.exe' @('C:\Program Files\CMake\bin\cmake.exe',
        "$vsRoot\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe")
    Ninja  = Find-Executable 'ninja.exe' @("$vsRoot\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe")
    Python = Find-Executable 'python.exe' @()
}

$recompFlags = Get-RecompilerFlags -FlagsFile (Join-Path $repoRoot "config\recomp\$GameId.flags") `
    -RegionsFile $(if ($NoRegions) { '' } else { Join-Path $repoRoot "config\recomp\$GameId.regions" }) `
    -HotList $(if ($NoTwin) { '' } else { Join-Path $repoRoot "build\pgo\$GameId.hot" }) `
    -ExcludeFlag $ExcludeFlag -ExtraFlag $ExtraFlag

Write-Host "==> 1/3  Recompiling main.dol"
Write-Host "    flags: $($recompFlags -join ' ')"
$generated = Invoke-Recompiler -DolRecomp $dolrecomp -Dol $dol -Flags $recompFlags -WorkDir $work -Jobs $Jobs

Write-Host "==> 2/3  Building the module with $(& $clang --version | Select-Object -First 1)"
$dll = Invoke-ModuleBuild -Toolchain $toolchain -ModuleSource $moduleSource -GeneratedDir $generated `
    -BuildDir $moduleBuild -GameId $GameId -CFlags $CFlags -Jobs $Jobs -PgoProfile $PgoProfile `
    -PgoInstrumentDir $PgoInstrumentDir -ModuleOption $ModuleOption

Write-Host "==> 3/3  Publishing"
New-Item -ItemType Directory -Force $moduleDir | Out-Null
$published = Join-Path $moduleDir "g${GameId}_recomp.dll"
Copy-Item $dll $published -Force
if (-not $Variant -and -not $PgoInstrumentDir) {
    # Relative to the repo root, as run.ps1 expects.
    "build\modules\$GameId\g${GameId}_recomp.dll" | Set-Content -Encoding ascii (Join-Path $moduleDir 'active-module.txt')
}
Write-Host "Module: $published"
