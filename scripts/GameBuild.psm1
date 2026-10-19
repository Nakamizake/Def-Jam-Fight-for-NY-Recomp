<#
.SYNOPSIS
    Builds the game module and prepares a user directory. Shared by the developer scripts
    (build-module.ps1, run.ps1) and the installed game's build-game.ps1, so the recompiler
    flags, the module's CMake options and the first-run settings live in one place.
#>

$ErrorActionPreference = 'Stop'

# Reads a recompiler flags file (one flag plus its value per line, '#' comments) and adds the
# optional per-game lists. A flag named in -ExcludeFlag is dropped with its value.
function Get-RecompilerFlags {
    param(
        [Parameter(Mandatory)] [string] $FlagsFile,
        # Native regions list (config/recomp/<id>.regions); skipped when empty or missing.
        [string] $RegionsFile = '',
        # Twin-chunk hot list made by train-twin.ps1; skipped when empty or missing.
        [string] $HotList = '',
        [string[]] $ExcludeFlag = @(),
        [string[]] $ExtraFlag = @()
    )
    $ExcludeFlag = @(Split-ListArgument $ExcludeFlag)
    $flags = @(Get-Content -LiteralPath $FlagsFile | ForEach-Object { ($_ -replace '#.*$', '').Trim() } |
        Where-Object { $_ -and (($_ -split '\s+')[0] -notin $ExcludeFlag) } | ForEach-Object { $_ -split '\s+' })
    $flags += @(Split-ListArgument $ExtraFlag)
    # Native regions: the listed hot functions run as native C, with their paired-single loads
    # and stores going straight to RAM when the recompiled code's own fast path would apply.
    if ($RegionsFile -and (Test-Path -LiteralPath $RegionsFile)) {
        $flags += @('--native-regions', (Resolve-Path -LiteralPath $RegionsFile).Path, '--region-psq')
    }
    # Twin chunks: a fast copy of every chunk entered only at the entry points a training run
    # used, with the ordinary chunk as the fallback for any other entry.
    if ($HotList -and (Test-Path -LiteralPath $HotList)) {
        $flags += @('--twin-hot', (Resolve-Path -LiteralPath $HotList).Path, '--twin-regs', 'ratio', '--twin-cr')
    }
    return $flags
}

# `powershell -File` passes a comma list as one string; accept both forms.
function Split-ListArgument([string[]] $Values) {
    return @($Values | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# Translates main.dol to C in <WorkDir>\out and returns the directory of generated sources.
function Invoke-Recompiler {
    param(
        [Parameter(Mandatory)] [string] $DolRecomp,
        [Parameter(Mandatory)] [string] $Dol,
        [Parameter(Mandatory)] [string[]] $Flags,
        [Parameter(Mandatory)] [string] $WorkDir,
        [int] $Jobs = 4
    )
    $out = Join-Path $WorkDir 'out'
    if (Test-Path -LiteralPath $out) { Remove-Item -Recurse -Force -LiteralPath $out }
    New-Item -ItemType Directory -Force $WorkDir | Out-Null
    # Tool output goes to the host, not the pipeline: these functions return a path.
    & $DolRecomp --gamecube $Dol @Flags "-j$Jobs" $out | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "dolrecomp failed ($LASTEXITCODE)." }
    $generated = Join-Path $out 'generated'
    # gen_module_tables.py reads main.dol from next to the generated sources.
    Copy-Item -LiteralPath $Dol (Join-Path $generated 'main.dol')
    return $generated
}

# Compiles generated sources into g<GameId>_recomp.dll with Clang through RingOut's module
# CMake project and returns the DLL's path. RingOut's generated code needs Clang
# (preserve_none, vector extensions, __builtin_choose_expr); MSVC cannot build it.
function Invoke-ModuleBuild {
    param(
        # Clang, CMake, Ninja and Python executables.
        [Parameter(Mandatory)] [hashtable] $Toolchain,
        # RingOut's module CMake project (dist/RingOut-1.0-dist/module-src).
        [Parameter(Mandatory)] [string] $ModuleSource,
        [Parameter(Mandatory)] [string] $GeneratedDir,
        [Parameter(Mandatory)] [string] $BuildDir,
        [string] $GameId = 'GNWE69',
        # C flags for the generated code. -march=native: the module is always built on the
        # machine that runs it.
        [string] $CFlags = '-march=native',
        [int] $Jobs = 4,
        # Profile to compile with (made by train-pgo.ps1); none when empty.
        [string] $PgoProfile = '',
        # Builds the module instrumented for PGO instead; a run writes .profraw counts here.
        [string] $PgoInstrumentDir = '',
        # Module CMake option overrides, e.g. MODULE_PSQ_FAST=OFF.
        [string[]] $ModuleOption = @()
    )
    $deps = Join-Path $ModuleSource 'deps'
    $configure = @(
        '-S', $ModuleSource, '-B', $BuildDir, '-G', 'Ninja',
        "-DCMAKE_MAKE_PROGRAM=$($Toolchain.Ninja)",
        '-DCMAKE_BUILD_TYPE=Release',
        "-DCMAKE_C_COMPILER=$($Toolchain.Clang)",
        "-DPython3_EXECUTABLE=$($Toolchain.Python)",
        "-DCMAKE_C_FLAGS=$CFlags",
        '-DMODULE_PSQ_FAST=ON', '-DMODULE_MEM_FAST=ON',
        # The cycle accumulator must live in CPUState, not a chunk local: the runtime pushes
        # it past the loop budget to make native code yield when the GX FIFO nears overflow
        # (StaticRecompCore::YieldNativeIfCheckForced). With it local, a vertex loop wrote on
        # for its whole budget and overflowed the FIFO on the first hit of a fight.
        '-DMODULE_DC_LOCAL=OFF',
        "-DGAME_ID=$GameId",
        "-DGENERATED_DIR=$GeneratedDir",
        "-DDOLRECOMP_SRC=$(Join-Path $deps 'dolrecomp-src')",
        "-DGXRUNTIME_INC=$(Join-Path $deps 'gxruntime-include')",
        "-DCHASSIS_ABI_DIR=$(Join-Path $deps 'chassis-abi')",
        "-DMODULE_TEMPLATE=$(Join-Path $deps 'module-template')"
    )
    $usePgo = $false
    if ($PgoInstrumentDir) {
        New-Item -ItemType Directory -Force $PgoInstrumentDir | Out-Null
        $profileDir = (Resolve-Path -LiteralPath $PgoInstrumentDir).Path
        # LTO must be off: instrumented objects are LTO IR, and linking them without LTO gives
        # a stub module that loads and does nothing (see MODULE_LTO in RingOut's CMakeLists).
        # MODULE_PROFILE_RESET exports staticrecomp_profile_reset, which lets a training
        # run drop the counts of boot and menus (automation command profile_reset).
        $configure += @("-DCMAKE_C_FLAGS=$CFlags -fprofile-generate=$profileDir -DMODULE_PROFILE_RESET",
            "-DCMAKE_SHARED_LINKER_FLAGS=-fprofile-generate=$profileDir", '-DMODULE_LTO=OFF',
            '-DMODULE_PGO_PROFILE=')
        Write-Host "    instrumented for PGO; counts go to $profileDir"
    }
    elseif ($PgoProfile -and (Test-Path -LiteralPath $PgoProfile)) {
        $usePgo = $true
        $configure += "-DMODULE_PGO_PROFILE=$((Resolve-Path -LiteralPath $PgoProfile).Path)"
        Write-Host "    profile-guided build with $PgoProfile"
    }
    else {
        # Cleared explicitly: CMake caches it, so a profile used once would stick.
        $configure += '-DMODULE_PGO_PROFILE='
    }
    # Later -D definitions win, so -ModuleOption overrides the defaults above.
    $configure += @(Split-ListArgument $ModuleOption | ForEach-Object { "-D$_" })

    & $Toolchain.CMake @configure | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Module configure failed.' }
    # Clang reads the profile while compiling, but the CMake project does not list it as an
    # input: after a retrain, objects whose source did not change (cpu.c, the module template)
    # would keep the old counts, and ThinLTO refuses to link modules with different profile
    # summaries.
    $profileStamp = Join-Path $BuildDir 'pgo-profile.sha256'
    $profileHash = if ($usePgo) { (Get-FileHash -LiteralPath $PgoProfile -Algorithm SHA256).Hash } else { 'none' }
    $builtWith = if (Test-Path -LiteralPath $profileStamp) { (Get-Content -LiteralPath $profileStamp -Raw).Trim() } else { '' }
    if ($builtWith -ne $profileHash) {
        & $Toolchain.CMake --build $BuildDir --target clean | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Module clean failed.' }
    }
    & $Toolchain.CMake --build $BuildDir -j $Jobs | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Module build failed.' }
    $profileHash | Set-Content -Encoding ascii -LiteralPath $profileStamp

    $dll = Join-Path $BuildDir "g${GameId}_recomp.dll"
    if (-not (Test-Path -LiteralPath $dll)) { throw "Module built but $dll is missing." }
    return $dll
}

# Parallel compile jobs that fit in memory: the largest generated chunks take over 1 GB each
# to compile, so a machine with many cores and little RAM must not use all of them.
function Get-ModuleBuildJobs {
    $cores = [Environment]::ProcessorCount
    $ramGb = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB
    return [int][Math]::Max(1, [Math]::Min($cores, [Math]::Floor($ramGb / 2)))
}

# Prepares a runtime user directory from the files in a config directory:
# - GameSettings\<id>.ini is copied every time (settings the player must not change; that
#   layer overrides the in-game menu);
# - Dolphin.defaults.ini keys are added to Config\Dolphin.ini only where missing, so a value
#   picked in the in-game menu is kept;
# - Controllers\GCPadNew.defaults.ini is copied whole, once (a profile is one coherent set of
#   bindings, so merging keys into a rebound one would scramble it).
function Initialize-UserDirectory {
    param(
        [Parameter(Mandatory)] [string] $UserDir,
        [Parameter(Mandatory)] [string] $ConfigDir,
        [string] $GameId = 'GNWE69'
    )
    New-Item -ItemType Directory -Force $UserDir | Out-Null

    $gameSettings = Join-Path $ConfigDir "GameSettings\$GameId.ini"
    if (Test-Path -LiteralPath $gameSettings) {
        $userGameSettings = Join-Path $UserDir 'GameSettings'
        New-Item -ItemType Directory -Force $userGameSettings | Out-Null
        Copy-Item -LiteralPath $gameSettings $userGameSettings -Force
    }

    $defaultSettings = Join-Path $ConfigDir 'Dolphin.defaults.ini'
    if (Test-Path -LiteralPath $defaultSettings) {
        Add-MissingIniKeys $defaultSettings (Join-Path $UserDir 'Config\Dolphin.ini')
    }

    $defaultPad = Join-Path $ConfigDir 'Controllers\GCPadNew.defaults.ini'
    $userPad = Join-Path $UserDir 'Config\GCPadNew.ini'
    if ((Test-Path -LiteralPath $defaultPad) -and -not (Test-Path -LiteralPath $userPad)) {
        New-Item -ItemType Directory -Force (Split-Path -Parent $userPad) | Out-Null
        Copy-Item -LiteralPath $defaultPad $userPad
    }
}

# Adds the keys of an ini file that the target does not have yet, section by section.
function Add-MissingIniKeys([string] $DefaultsPath, [string] $TargetPath) {
    $lines = [Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $TargetPath) { $lines.AddRange([string[]](Get-Content -LiteralPath $TargetPath)) }
    $section = ''
    $changed = $false
    foreach ($raw in Get-Content -LiteralPath $DefaultsPath) {
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

Export-ModuleMember -Function Get-RecompilerFlags, Invoke-Recompiler, Invoke-ModuleBuild,
    Get-ModuleBuildJobs, Initialize-UserDirectory
