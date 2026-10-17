<#
.SYNOPSIS
    Builds the runtime (moderngekko-run) and the recompiler (dolrecomp) from lib/RingOut.

.DESCRIPTION
    lib/RingOut carries the RingOut fork of DolRecomp and ModernGekko, which is much faster
    than upstream (inlined float/memory helpers, direct calls, fewer dispatcher returns).
    The runtime and recompiler are built with MSVC and the Ninja bundled with Visual
    Studio 2022, exactly like RingOut's own Windows CI. Only the game module needs Clang
    (see build-module.ps1).

    Output goes to build/runtime (or build/runtime-prof with -Profiling). The first build
    takes a while (~1700 steps).

.EXAMPLE
    .\scripts\build-tools.ps1
    .\scripts\build-tools.ps1 -Clean
    .\scripts\build-tools.ps1 -Profiling

.PARAMETER Profiling
    Builds into build/runtime-prof with the same optimization as Release plus debug
    symbols (PDB), so profiler samples can be resolved to function names.

.PARAMETER NoPatch
    Builds lib/RingOut as it is, without checking or applying patches/RingOut (for
    in-place edits that are not saved as a patch yet; see save-ringout-patch.ps1).
#>
[CmdletBinding()]
param([switch] $Clean, [switch] $Profiling, [switch] $NoPatch)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'VsDevEnv.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'RingOutPatches.psm1') -Force

$repoRoot = Split-Path -Parent $PSScriptRoot
$stack = Join-Path $repoRoot 'lib\RingOut'
$source = Join-Path $stack 'ModernGekko'
$build = Join-Path $repoRoot ($(if ($Profiling) { 'build\runtime-prof' } else { 'build\runtime' }))

if (-not (Test-Path (Join-Path $source 'vendor\dolphin\CMakeLists.txt'))) {
    throw 'lib/RingOut is missing. Run: git submodule update --init --depth 1 lib/RingOut'
}
if ($Clean -and (Test-Path $build)) { Remove-Item -Recurse -Force $build }

# Local changes to the stack live in patches/RingOut/ and are applied in place; only the
# part of the series the tree does not have yet is applied.
if (-not $NoPatch) {
    Sync-RingOutPatches -Stack $stack -PatchDirectory (Join-Path $repoRoot 'patches\RingOut')
}

# Same switches as RingOut's Windows CI (Qt, tests, analytics and updater off).
$configure = "cmake -S `"$source`" -B `"$build`" -G Ninja -DCMAKE_BUILD_TYPE=Release " +
    '-DBUILD_TESTING=OFF -DENABLE_QT=OFF -DENABLE_TESTS=OFF -DENABLE_ANALYTICS=OFF -DENABLE_AUTOUPDATE=OFF'
if ($Profiling) {
    # Release optimization plus /Z7 (debug info in the objects, no shared PDB lock) and a linked PDB.
    $configure += ' "-DCMAKE_C_FLAGS_RELEASE=/O2 /Ob2 /DNDEBUG /Z7"' +
        ' "-DCMAKE_CXX_FLAGS_RELEASE=/O2 /Ob2 /DNDEBUG /Z7"' +
        ' "-DCMAKE_EXE_LINKER_FLAGS_RELEASE=/INCREMENTAL:NO /DEBUG /OPT:REF /OPT:ICF"'
}
Invoke-InVsDevEnv $configure
Invoke-InVsDevEnv "cmake --build `"$build`" --target moderngekko-run dolrecomp"

Write-Host "Tools built in $build"
