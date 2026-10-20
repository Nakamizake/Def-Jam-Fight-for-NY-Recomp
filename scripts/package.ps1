<#
.SYNOPSIS
    Builds the Windows installer (build/package/DefJamFFNY-Setup-<version>.exe).

.DESCRIPTION
    Stages everything the installed game needs to build itself from the player's disc and
    run, then compiles installer/DefJamFFNY.iss with Inno Setup:

      DefJam.exe     launcher (installer/launcher/DefJam.c, built with the staged Clang)
      bin\           moderngekko-run.exe, dolrecomp.exe, their MSVC runtime DLLs, Sys\
      toolchain\     llvm-mingw (trimmed, with its Python), CMake and Ninja
      module-src\    RingOut's module CMake project
      config\        recompiler flags and regions, game settings, first-run defaults, layouts
                     and the button icon art
      setup\         build-game.ps1, GameBuild.psm1 and AutoPlay.psm1 (for -Optimize)
      modding\       viv.py / refpack.py (the .viv archive tool) and the modding guide
      licenses\      licences of everything bundled

    Nothing derived from the disc is staged: no extracted files, generated code, module,
    profile or hot list. The script checks this before compiling the installer.

    Needs: build-tools.ps1 output in build/runtime, tools/llvm-mingw, CMake, Visual Studio's
    Ninja and MSVC runtime, and Inno Setup 6 (ISCC.exe).

.EXAMPLE
    .\scripts\package.ps1 -Version 0.1.0
    .\scripts\package.ps1 -StageOnly
#>
[CmdletBinding()]
param(
    [string] $Version = '0.1.0',
    # Stops after staging (no installer).
    [switch] $StageOnly,
    # Compiles the installer from the existing stage (after editing only the .iss).
    [switch] $ReuseStage,
    # Developer test build: creates no uninstall entry in the registry (see the .iss).
    [switch] $TestInstall
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$packageDir = Join-Path $repoRoot 'build\package'
$stage = Join-Path $packageDir 'stage'
$runtimeBuild = Join-Path $repoRoot 'build\runtime'
$llvmMingw = Join-Path $repoRoot 'tools\llvm-mingw'
$ringOutDist = Join-Path $repoRoot 'lib\RingOut\dist\RingOut-1.0-dist'

function Find-FirstExisting([string] $What, [string[]] $Candidates) {
    foreach ($candidate in $Candidates) { if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate } }
    throw "$What not found (looked in: $($Candidates -join '; '))."
}

function Get-VisualStudioPath {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere) {
        $path = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if ($path) { return $path }
    }
    throw 'Visual Studio 2022 with the C++ workload was not found.'
}

function Copy-Tree([string] $From, [string] $To) {
    New-Item -ItemType Directory -Force $To | Out-Null
    # robocopy: fast for the toolchain's thousands of files. Exit codes below 8 are success.
    & robocopy $From $To /E /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Copying $From failed (robocopy $LASTEXITCODE)." }
    $global:LASTEXITCODE = 0
}

$vsPath = Get-VisualStudioPath
$runner = Join-Path $runtimeBuild 'moderngekko-run.exe'
$dolrecomp = Join-Path $runtimeBuild 'dolrecomp-build\dolrecomp.exe'
$cmakeRoot = Find-FirstExisting 'CMake' @('C:\Program Files\CMake')
$ninja = Find-FirstExisting 'Ninja' @("$vsPath\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe")
$iscc = Find-FirstExisting 'Inno Setup 6 (ISCC.exe)' @(
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe")
foreach ($required in $runner, $dolrecomp, (Join-Path $llvmMingw 'bin\clang.exe')) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Missing $required. Run scripts\build-tools.ps1 (and see docs/external-footprint.md)." }
}

if ($ReuseStage -and (Test-Path -LiteralPath (Join-Path $stage 'DefJam.exe'))) {
    Write-Host "==> Reusing $stage"
}
else {
Write-Host '==> Staging'
if (Test-Path -LiteralPath $stage) { Remove-Item -Recurse -Force -LiteralPath $stage }
New-Item -ItemType Directory -Force $stage | Out-Null

# bin: the runtime with its Sys folder (fonts, shaders, game settings), the recompiler, and
# the MSVC runtime DLLs both link against (app-local, as Microsoft's redistribution terms allow).
$bin = Join-Path $stage 'bin'
New-Item -ItemType Directory -Force $bin | Out-Null
Copy-Item -LiteralPath $runner, $dolrecomp $bin
Copy-Tree (Join-Path $runtimeBuild 'Sys') (Join-Path $bin 'Sys')
$crt = Get-ChildItem (Join-Path $vsPath 'VC\Redist\MSVC') -Directory |
    Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } | Sort-Object { [version]$_.Name } -Descending |
    ForEach-Object { Join-Path $_.FullName 'x64\Microsoft.VC143.CRT' } |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $crt) { throw 'MSVC runtime redistributables not found in Visual Studio.' }
foreach ($dll in 'msvcp140.dll', 'msvcp140_atomic_wait.dll', 'vcruntime140.dll', 'vcruntime140_1.dll') {
    Copy-Item -LiteralPath (Join-Path $crt $dll) $bin
}

# toolchain: llvm-mingw without what a module build never touches. Keep include\,
# x86_64-w64-mingw32\ and lib\clang\: together they are the compiler's sysroot.
$toolchain = Join-Path $stage 'toolchain'
Copy-Tree $llvmMingw $toolchain
foreach ($triple in 'aarch64-w64-mingw32', 'arm64ec-w64-mingw32', 'armv7-w64-mingw32', 'i686-w64-mingw32') {
    Remove-Item -Recurse -Force -LiteralPath (Join-Path $toolchain $triple) -ErrorAction SilentlyContinue
}
Get-ChildItem (Join-Path $toolchain 'bin') -File |
    Where-Object { $_.Name -match '^(aarch64|arm64ec|armv7|i686)-w64-|^(lldb|clangd|clang-repl|clang-check|clang-tidy|clang-format|clang-refactor|clang-rename|clang-scan-deps|clang-doc|clang-linker-wrapper|llvm-lto|llvm-reduce|llvm-exegesis|bugpoint|opt|llc|lli|llvm-cfi-verify)' -or $_.Name -eq 'liblldb.dll' } |
    Remove-Item -Force
foreach ($unused in 'share\doc', 'share\man', 'python\lib\python3.14\idlelib', 'python\lib\python3.14\tkinter',
                    'python\lib\python3.14\ensurepip', 'python\lib\python3.14\site-packages\lldb') {
    Remove-Item -Recurse -Force -LiteralPath (Join-Path $toolchain $unused) -ErrorAction SilentlyContinue
}
Get-ChildItem (Join-Path $toolchain 'lib\clang') -Directory | ForEach-Object {
    Remove-Item -Recurse -Force -LiteralPath (Join-Path $_.FullName 'lib\linux') -ErrorAction SilentlyContinue
}
# CMake beside Clang: cmake.exe finds its modules at ..\share\cmake-X.Y, so bin\ and share\
# stay siblings. Ninja is a single executable.
Copy-Item -LiteralPath (Join-Path $cmakeRoot 'bin\cmake.exe') (Join-Path $toolchain 'bin')
Copy-Tree (Join-Path $cmakeRoot 'share') (Join-Path $toolchain 'share')
Copy-Item -LiteralPath $ninja (Join-Path $toolchain 'bin')

# module-src without RingOut's SoulCalibur II PGO profiles (no use for this game).
Copy-Tree (Join-Path $ringOutDist 'module-src') (Join-Path $stage 'module-src')
Remove-Item -Recurse -Force -LiteralPath (Join-Path $stage 'module-src\profiles') -ErrorAction SilentlyContinue

# config and setup
$config = Join-Path $stage 'config'
New-Item -ItemType Directory -Force (Join-Path $config 'recomp') | Out-Null
Copy-Item (Join-Path $repoRoot 'config\recomp\GNWE69.flags'), (Join-Path $repoRoot 'config\recomp\GNWE69.regions') (Join-Path $config 'recomp')
Copy-Tree (Join-Path $repoRoot 'config\GameSettings') (Join-Path $config 'GameSettings')
Copy-Tree (Join-Path $repoRoot 'config\Controllers') (Join-Path $config 'Controllers')
Copy-Tree (Join-Path $repoRoot 'config\ButtonIcons') (Join-Path $config 'ButtonIcons')
Copy-Item (Join-Path $repoRoot 'config\Dolphin.defaults.ini') $config
$setup = Join-Path $stage 'setup'
New-Item -ItemType Directory -Force $setup | Out-Null
Copy-Item (Join-Path $repoRoot 'installer\build-game.ps1'), (Join-Path $PSScriptRoot 'GameBuild.psm1'),
    (Join-Path $PSScriptRoot 'AutoPlay.psm1') $setup
# build-game.ps1 -Optimize merges the training counts with llvm-profdata, and the measuring
# build links Clang's profile runtime; both must survive the toolchain trim above.
foreach ($needed in 'bin\llvm-profdata.exe', 'lib\clang\*\lib\windows\libclang_rt.profile-x86_64.a') {
    if (-not (Test-Path (Join-Path $toolchain $needed))) { throw "The trimmed toolchain lacks $needed." }
}
Copy-Item (Join-Path $repoRoot 'installer\before-you-install.txt') (Join-Path $stage 'README.txt')
# modding: the .viv archive tool and the guide, run with the staged Python.
$modding = Join-Path $stage 'modding'
New-Item -ItemType Directory -Force $modding | Out-Null
Copy-Item (Join-Path $repoRoot 'tools-src\modding\viv.py'), (Join-Path $repoRoot 'tools-src\modding\refpack.py') $modding
Copy-Item (Join-Path $repoRoot 'docs\modding.md') (Join-Path $modding 'README.md')

# licenses
$licenses = Join-Path $stage 'licenses'
New-Item -ItemType Directory -Force $licenses | Out-Null
Copy-Item (Join-Path $repoRoot 'lib\RingOut\LICENSE') (Join-Path $licenses 'RingOut-GPL-2.0.txt')
Copy-Item (Join-Path $repoRoot 'lib\RingOut\ModernGekko\vendor\dolphin\COPYING') (Join-Path $licenses 'Dolphin-COPYING.txt')
Copy-Tree (Join-Path $repoRoot 'lib\RingOut\ModernGekko\vendor\dolphin\LICENSES') (Join-Path $licenses 'Dolphin-LICENSES')
Copy-Item (Join-Path $llvmMingw 'LICENSE.TXT') (Join-Path $licenses 'llvm-mingw-LICENSE.txt')
Copy-Item (Join-Path $llvmMingw 'python\LICENSE.txt') (Join-Path $licenses 'Python-LICENSE.txt')
Copy-Item (Join-Path $cmakeRoot 'doc\cmake\LICENSE.rst') (Join-Path $licenses 'CMake-LICENSE.txt')
@'
Bundled components and their licences

- moderngekko-run.exe, dolrecomp.exe, module-src\: RingOut (DolRecomp + ModernGekko, built
  on Dolphin), GPL-2.0-or-later. RingOut-GPL-2.0.txt, Dolphin-COPYING.txt, Dolphin-LICENSES\.
  Source: https://github.com/jackpoison-prog/RingOut, plus this port's patches.
- toolchain\ (Clang, LLD, mingw-w64 headers and libraries): llvm-mingw, Apache-2.0 with LLVM
  exceptions and others. llvm-mingw-LICENSE.txt.
- toolchain\python\: Python, PSF License. Python-LICENSE.txt.
- toolchain\bin\cmake.exe, toolchain\share\cmake-*: CMake, BSD-3-Clause. CMake-LICENSE.txt.
- toolchain\bin\ninja.exe: Ninja, Apache-2.0 (licence text as in llvm-mingw-LICENSE.txt).
- bin\msvcp140*.dll, bin\vcruntime140*.dll: Microsoft Visual C++ runtime, redistributed under
  the Visual Studio redistribution terms.

No game data is included. The game is built on the player's machine from their own disc.
'@ | Set-Content -Encoding utf8 (Join-Path $licenses 'README.txt')

# The launcher, compiled with the STAGED Clang: this doubles as a check that the trim above left
# a working compiler (and the same ThinLTO path the module build uses).
Write-Host '==> Launcher (also checks the trimmed toolchain)'
$stagedClang = Join-Path $toolchain 'bin\clang.exe'
& $stagedClang (Join-Path $repoRoot 'installer\launcher\DefJam.c') -o (Join-Path $stage 'DefJam.exe') `
    -municode -mwindows -O2 -s -flto=thin -Wall -Wextra -lcomdlg32 -lshell32
if ($LASTEXITCODE -ne 0) { throw 'Launcher build failed: the trimmed toolchain is broken.' }
& (Join-Path $toolchain 'python\bin\python.exe') -I -c 'import re, sys, pathlib'
if ($LASTEXITCODE -ne 0) { throw 'The staged Python does not run.' }
& (Join-Path $toolchain 'bin\cmake.exe') --version | Select-Object -First 1 | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'The staged CMake does not run.' }

# Never ship anything derived from the disc.
$forbidden = Get-ChildItem -LiteralPath $stage -Recurse -File |
    Where-Object { $_.Extension -in '.iso', '.gcm', '.rvz', '.dol', '.rel', '.profdata', '.profraw', '.hot', '.sav' -or
                   $_.Name -like 'g*_recomp.dll' -or $_.FullName -match '\\(generated|extracted)\\' }
if ($forbidden) { throw "Game-derived files found in the stage:`n$($forbidden.FullName -join "`n")" }

$size = (Get-ChildItem -LiteralPath $stage -Recurse -File | Measure-Object Length -Sum).Sum
Write-Host ("    staged {0:N0} MB in {1}" -f ($size / 1MB), $stage)
}
if ($StageOnly) { return }

Write-Host '==> Installer'
$isccArgs = @("/DAppVersion=$Version", "/DStageDir=$stage", "/DOutputDir=$packageDir")
if ($TestInstall) { $isccArgs += '/DTestInstall' }
& $iscc @isccArgs (Join-Path $repoRoot 'installer\DefJamFFNY.iss')
if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed ($LASTEXITCODE)." }
Write-Host "Installer: $(Join-Path $packageDir "DefJamFFNY-Setup-$Version.exe")"
