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

$repoRoot = Split-Path -Parent $PSScriptRoot
$dolrecomp = Join-Path $repoRoot 'build\runtime\dolrecomp-build\dolrecomp.exe'
$clang = Join-Path $repoRoot 'tools\llvm-mingw\bin\clang.exe'
$moduleSource = Join-Path $repoRoot 'lib\RingOut\dist\RingOut-1.0-dist\module-src'
$deps = Join-Path $moduleSource 'deps'
$dol = Join-Path $repoRoot "extracted\$GameId\sys\main.dol"
$flagsFile = Join-Path $repoRoot "config\recomp\$GameId.flags"
$variantSuffix = if ($Variant) { "-$Variant" } else { '' }
$work = Join-Path $repoRoot "build\module-work\$GameId$variantSuffix"
$generated = Join-Path $work 'out\generated'
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
$usePgo = -not $NoPgo -and (Test-Path $PgoProfile)

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
$cmake = Find-Executable 'cmake.exe' @('C:\Program Files\CMake\bin\cmake.exe',
    "$vsRoot\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe")
$ninja = Find-Executable 'ninja.exe' @("$vsRoot\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe")
$python = Find-Executable 'python.exe' @()

# Flags file: one flag (plus value) per line, '#' comments. A line is excluded whole (flag
# plus value) by -ExcludeFlag; `powershell -File` passes a comma list as one string.
$ExcludeFlag = @($ExcludeFlag | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$recompFlags = @(Get-Content $flagsFile | ForEach-Object { ($_ -replace '#.*$', '').Trim() } |
    Where-Object { $_ -and (($_ -split '\s+')[0] -notin $ExcludeFlag) } | ForEach-Object { $_ -split '\s+' })
$recompFlags += @($ExtraFlag | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
# Native regions: the listed hot functions run as native C, with their paired-single loads and
# stores going straight to RAM when the recompiled code's own fast path would apply.
$regionList = Join-Path $repoRoot "config\recomp\$GameId.regions"
if (-not $NoRegions -and (Test-Path $regionList)) {
    $recompFlags += @('--native-regions', (Resolve-Path $regionList).Path, '--region-psq')
}
# Twin chunks: a fast copy of every chunk entered only at the entry points a training run used
# (made by train-twin.ps1), with the ordinary chunk as the fallback for any other entry.
$hotList = Join-Path $repoRoot "build\pgo\$GameId.hot"
if (-not $NoTwin -and (Test-Path $hotList)) {
    $recompFlags += @('--twin-hot', (Resolve-Path $hotList).Path, '--twin-regs', 'ratio', '--twin-cr')
}

Write-Host "==> 1/3  Recompiling main.dol"
Write-Host "    flags: $($recompFlags -join ' ')"
if (Test-Path (Join-Path $work 'out')) { Remove-Item -Recurse -Force (Join-Path $work 'out') }
New-Item -ItemType Directory -Force $work | Out-Null
& $dolrecomp --gamecube $dol @recompFlags "-j$Jobs" (Join-Path $work 'out')
if ($LASTEXITCODE -ne 0) { throw "dolrecomp failed ($LASTEXITCODE)." }
# gen_module_tables.py reads main.dol from next to the generated sources.
Copy-Item $dol (Join-Path $generated 'main.dol')

Write-Host "==> 2/3  Building the module with $(& $clang --version | Select-Object -First 1)"
$configure = @(
    '-S', $moduleSource, '-B', $moduleBuild, '-G', 'Ninja',
    "-DCMAKE_MAKE_PROGRAM=$ninja",
    '-DCMAKE_BUILD_TYPE=Release',
    "-DCMAKE_C_COMPILER=$clang",
    "-DPython3_EXECUTABLE=$python",
    "-DCMAKE_C_FLAGS=$CFlags",
    '-DMODULE_PSQ_FAST=ON', '-DMODULE_MEM_FAST=ON',
    # The cycle accumulator must live in CPUState, not a chunk local: the runtime pushes
    # it past the loop budget to make native code yield when the GX FIFO nears overflow
    # (StaticRecompCore::YieldNativeIfCheckForced). With it local, a vertex loop wrote on
    # for its whole budget and overflowed the FIFO on the first hit of a fight.
    '-DMODULE_DC_LOCAL=OFF',
    "-DGAME_ID=$GameId",
    "-DGENERATED_DIR=$generated",
    "-DDOLRECOMP_SRC=$(Join-Path $deps 'dolrecomp-src')",
    "-DGXRUNTIME_INC=$(Join-Path $deps 'gxruntime-include')",
    "-DCHASSIS_ABI_DIR=$(Join-Path $deps 'chassis-abi')",
    "-DMODULE_TEMPLATE=$(Join-Path $deps 'module-template')"
)
if ($PgoInstrumentDir) {
    New-Item -ItemType Directory -Force $PgoInstrumentDir | Out-Null
    $profileDir = (Resolve-Path $PgoInstrumentDir).Path
    # LTO must be off: instrumented objects are LTO IR, and linking them without LTO gives a
    # stub module that loads and does nothing (see MODULE_LTO in RingOut's CMakeLists).
    $configure += @("-DCMAKE_C_FLAGS=$CFlags -fprofile-generate=$profileDir",
        "-DCMAKE_SHARED_LINKER_FLAGS=-fprofile-generate=$profileDir", '-DMODULE_LTO=OFF')
    Write-Host "    instrumented for PGO; counts go to $profileDir"
}
elseif ($usePgo) {
    $configure += "-DMODULE_PGO_PROFILE=$((Resolve-Path $PgoProfile).Path)"
    Write-Host "    profile-guided build with $PgoProfile"
}
else {
    # Cleared explicitly: CMake caches it, so a profile used once would stick.
    $configure += '-DMODULE_PGO_PROFILE='
}
# Later -D definitions win, so -ModuleOption overrides the defaults above.
$configure += @($ModuleOption | ForEach-Object { $_ -split ',' } | Where-Object { $_ } | ForEach-Object { "-D$($_.Trim())" })
& $cmake @configure
if ($LASTEXITCODE -ne 0) { throw 'Module configure failed.' }
# Clang reads the profile while compiling, but the CMake project does not list it as an input:
# after a retrain, objects whose source did not change (cpu.c, the module template) would keep
# the old counts, and ThinLTO refuses to link modules with different profile summaries.
$profileStamp = Join-Path $moduleBuild 'pgo-profile.sha256'
$profileHash = if ($usePgo) { (Get-FileHash $PgoProfile -Algorithm SHA256).Hash } else { 'none' }
$builtWith = if (Test-Path $profileStamp) { (Get-Content $profileStamp -Raw).Trim() } else { '' }
if ($builtWith -ne $profileHash) {
    & $cmake --build $moduleBuild --target clean
    if ($LASTEXITCODE -ne 0) { throw 'Module clean failed.' }
}
& $cmake --build $moduleBuild -j $Jobs
if ($LASTEXITCODE -ne 0) { throw 'Module build failed.' }
$profileHash | Set-Content -Encoding ascii $profileStamp

Write-Host "==> 3/3  Publishing"
$dll = Join-Path $moduleBuild "g${GameId}_recomp.dll"
if (-not (Test-Path $dll)) { throw "Module built but $dll is missing." }
New-Item -ItemType Directory -Force $moduleDir | Out-Null
$published = Join-Path $moduleDir "g${GameId}_recomp.dll"
Copy-Item $dll $published -Force
if (-not $Variant -and -not $PgoInstrumentDir) {
    # Relative to the repo root, as run.ps1 expects.
    "build\modules\$GameId\g${GameId}_recomp.dll" | Set-Content -Encoding ascii (Join-Path $moduleDir 'active-module.txt')
}
Write-Host "Module: $published"
