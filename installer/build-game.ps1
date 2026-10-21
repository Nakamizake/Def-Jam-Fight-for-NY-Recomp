<#
.SYNOPSIS
    Builds the game on the player's machine from their own disc image. Shipped with the
    installed game and run by the installer and by DefJam.exe; nothing game-derived ships
    with the package.

.DESCRIPTION
    1. Checks the disc image: a plain GameCube .iso of Def Jam: Fight for NY (USA, GNWE69).
    2. Extracts it to game\ with dolrecomp.
    3. Recompiles main.dol to C and builds module\gGNWE69_recomp.dll with the bundled Clang.
    4. Prepares userdata\ (game settings, first-run defaults, controller layout).

    With -Optimize, step 3 becomes profile-guided optimisation (PGO): a measuring build of
    the module, a few minutes of the game playing fights on its own (AutoPlay.psm1, with the
    player's input locked out and a throwaway memory card), then the real build using those
    measurements. The profile is kept in module\, so a later rebuild stays optimised as
    long as the recompiler, its settings and the compiler are the same.

    Everything happens inside the install folder; the work files are deleted at the end.
    A log is kept in logs\build-game.log.

.EXAMPLE
    .\build-game.ps1 -Iso D:\Games\DefJam.iso
    .\build-game.ps1            # rebuilds the module from the already extracted game
    .\build-game.ps1 -Optimize  # rebuilds it optimised for this PC (about 20 minutes)
#>
[CmdletBinding()]
param(
    # The player's disc image. Optional when game\ was already extracted.
    [string] $Iso = '',
    # Parallel compile jobs; by default as many as cores and memory allow.
    [int] $Jobs = 0,
    # Trains a PGO profile by letting the game play itself, and builds with it.
    [switch] $Optimize,
    # Seconds of fighting the profile is trained on.
    [int] $TrainSeconds = 240,
    # Closes the window straight away on failure too (for unattended runs).
    [switch] $NoPause
)

$ErrorActionPreference = 'Stop'
$GameId = 'GNWE69'
$app = Split-Path -Parent $PSScriptRoot
$paths = @{
    Bin          = Join-Path $app 'bin'
    Toolchain    = Join-Path $app 'toolchain'
    ModuleSource = Join-Path $app 'module-src'
    Config       = Join-Path $app 'config'
    Game         = Join-Path $app 'game'
    Module       = Join-Path $app 'module'
    UserData     = Join-Path $app 'userdata'
    Work         = Join-Path $app 'work'
    Logs         = Join-Path $app 'logs'
}
$profilePaths = @{
    Profile = Join-Path $paths.Module "$GameId.profdata"
    # What the profile was trained against; see Get-ProfileStamp.
    Stamp   = Join-Path $paths.Module "$GameId.profdata.stamp"
    # What the module was built from; see Get-ModuleStamp.
    ModuleStamp = Join-Path $paths.Module "$GameId.module.stamp"
}
Import-Module (Join-Path $PSScriptRoot 'GameBuild.psm1') -Force

# Explains what went wrong in the player's terms, then leaves the window open long enough
# to be read.
function Stop-Build([string] $Message) {
    Write-Host ''
    Write-Host $Message -ForegroundColor Red
    Write-Host ''
    Write-Host "Log: $(Join-Path $paths.Logs 'build-game.log')"
    try { Stop-Transcript | Out-Null } catch { }
    if (-not $NoPause) { Read-Host 'Press Enter to close' | Out-Null }
    exit 1
}

# Reads the disc header and returns its 6-character ID, or stops with advice on what the file
# actually is. dolrecomp wants a plain image: GameCube magic C2 33 9F 3D at offset 0x1C.
function Test-DiscImage([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Stop-Build "Disc image not found: $Path" }
    $extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($extension -ne '.iso') {
        Stop-Build @"
'$extension' images cannot be read directly; only plain .iso files are supported.

Convert it first. In Dolphin: right-click the game > Convert File..., format ISO.
"@
    }
    $header = New-Object byte[] 32
    $stream = [IO.File]::OpenRead($Path)
    try { $null = $stream.Read($header, 0, 32) } finally { $stream.Dispose() }
    $discId = -join ($header[0..5] | ForEach-Object { if ($_ -ge 32 -and $_ -lt 127) { [char]$_ } else { '.' } })
    $sizeMb = [int]((Get-Item -LiteralPath $Path).Length / 1MB)
    $gameCube = $header[0x1C] -eq 0xC2 -and $header[0x1D] -eq 0x33 -and $header[0x1E] -eq 0x9F -and $header[0x1F] -eq 0x3D
    if (-not $gameCube) {
        if ($sizeMb -gt 1500) {
            Stop-Build @"
That image is $sizeMB MB, too large for a GameCube disc (at most ~1400 MB).

It is probably the PlayStation 2 or Xbox release. This port recompiles the GameCube
version only.
"@
        }
        Stop-Build @"
That .iso is not a plain GameCube disc image (disc id read: '$discId', $sizeMb MB).

It is probably compressed (NKit, or an RVZ/GCZ renamed to .iso). In Dolphin:
right-click the game > Convert File..., format ISO, no compression.
"@
    }
    if ($discId -ne $GameId) {
        Stop-Build @"
That is a GameCube disc, but not Def Jam: Fight for NY (USA). Disc id read: '$discId'.

This port is built for the USA release, whose disc id is $GameId.
"@
    }
    return $discId
}

# A compiler that is present is not necessarily one that works: an antivirus quarantine or
# a damaged install fails here in a second instead of minutes into the build.
function Test-Compiler([string] $Clang) {
    $probe = Join-Path ([IO.Path]::GetTempPath()) ("defjam-probe-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Force $probe | Out-Null
    try {
        $source = Join-Path $probe 'probe.c'
        'int main(void) { return 0; }' | Set-Content -LiteralPath $source -Encoding ascii
        & $Clang $source -o (Join-Path $probe 'probe.exe') 2>&1 | Out-Null
        return $LASTEXITCODE -eq 0
    }
    finally {
        Remove-Item -Recurse -Force -LiteralPath $probe -ErrorAction SilentlyContinue
    }
}

# A profile only fits the code it was measured on: that code comes from the recompiler, its
# settings and the compiler, so their hashes identify it (the disc is always GNWE69).
function Get-ProfileStamp([string[]] $Inputs) {
    return ($Inputs | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash }) -join "`n"
}

# Everything the compiled module is made from: the tools and recompiler settings (the profile
# stamp), the game's code, the module's sources and the PGO profile it was built with.
function Get-ModuleStamp([string] $ProfileStamp, [string] $PgoProfile) {
    $root = (Resolve-Path -LiteralPath $paths.ModuleSource).Path
    $sources = Get-ChildItem -LiteralPath $root -Recurse -File | Sort-Object FullName | ForEach-Object {
        '{0} {1}' -f $_.FullName.Substring($root.Length), (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    }
    $dol = (Get-FileHash -LiteralPath (Join-Path $paths.Game 'sys\main.dol') -Algorithm SHA256).Hash
    $pgo = if ($PgoProfile) { (Get-FileHash -LiteralPath $PgoProfile -Algorithm SHA256).Hash } else { 'no profile' }
    return (@($ProfileStamp, $dol, $pgo) + $sources) -join "`n"
}

# True when the installed module was built from exactly what is installed now.
function Test-ModuleUpToDate {
    $module = Join-Path $paths.Module "g${GameId}_recomp.dll"
    if (-not (Test-Path -LiteralPath $module) -or -not (Test-Path -LiteralPath $profilePaths.ModuleStamp) -or
        -not (Test-Path -LiteralPath (Join-Path $paths.Game 'sys\main.dol'))) {
        return $false
    }
    $stamp = Get-ProfileStamp @((Join-Path $paths.Bin 'dolrecomp.exe'), (Join-Path $paths.Toolchain 'bin\clang.exe'),
        (Join-Path $paths.Config "recomp\$GameId.flags"), (Join-Path $paths.Config "recomp\$GameId.regions"))
    $current = Get-ModuleStamp $stamp (Get-SavedProfile $stamp)
    return (Get-Content -LiteralPath $profilePaths.ModuleStamp -Raw).Trim() -eq $current.Trim()
}

# The profile from an earlier -Optimize run, when it still fits this build; '' otherwise.
function Get-SavedProfile([string] $Stamp) {
    if (-not (Test-Path -LiteralPath $profilePaths.Profile) -or -not (Test-Path -LiteralPath $profilePaths.Stamp)) { return '' }
    if ((Get-Content -LiteralPath $profilePaths.Stamp -Raw).Trim() -ne $Stamp) { return '' }
    return $profilePaths.Profile
}

# Builds a measuring module, lets the game play fights with it and merges the counts into
# a profile. Returns the profile's path.
function Invoke-ProfileTraining([hashtable] $Toolchain, [string] $Generated) {
    $rawDir = Join-Path $paths.Work 'pgo-raw'
    if (Test-Path -LiteralPath $rawDir) { Remove-Item -Recurse -Force -LiteralPath $rawDir }
    $instrumented = Invoke-ModuleBuild -Toolchain $Toolchain -ModuleSource $paths.ModuleSource `
        -GeneratedDir $Generated -BuildDir (Join-Path $paths.Work 'build-train') -GameId $GameId `
        -Jobs $Jobs -PgoInstrumentDir $rawDir

    $minutes = [math]::Ceiling($TrainSeconds * 1.4 / 60) + 2
    Write-Host "==> $(Get-StepLabel)  Letting the game play itself (about $minutes min)"
    Write-Host '    A game window opens and plays on its own; your keyboard and controllers are'
    Write-Host '    ignored in it. Closing it cancels the optimisation (the game stays as it was).'
    Import-Module (Join-Path $PSScriptRoot 'AutoPlay.psm1') -Force
    # One counts file per game process; a restarted attempt adds its own.
    $env:LLVM_PROFILE_FILE = Join-Path $rawDir '%p.profraw'
    try {
        $fought = Invoke-AutoPlay -Runner (Join-Path $paths.Bin 'moderngekko-run.exe') -GameRoot $paths.Game `
            -Module $instrumented -UserDir (Join-Path $paths.Work 'train-user') -ConfigDir $paths.Config `
            -AutomationDir (Join-Path $paths.Work 'train-auto') -FightSeconds $TrainSeconds -MaxAttempts 5 -FightsOnlyProfile `
            -BannerHeading 'OPTIMIZING FOR YOUR PC' `
            -BannerBody "The game is playing itself to measure how it runs. About {0} min left.`nKeyboard and controllers are ignored. Closing this window cancels the optimization." `
            -LogFile (Join-Path $paths.Logs 'optimize-game')
    }
    finally { Remove-Item Env:LLVM_PROFILE_FILE -ErrorAction SilentlyContinue }
    $raw = @(Get-ChildItem -LiteralPath $rawDir -Filter *.profraw -ErrorAction SilentlyContinue | Where-Object Length -gt 0)
    # Half the fighting is plenty for a useful profile; less means the route kept failing or
    # the window was closed.
    if ($fought -lt $TrainSeconds / 2 -or $raw.Count -eq 0) {
        throw ("the game did not get far enough on its own ({0:N0} of {1} s of fighting). The game was left as it was." -f $fought, $TrainSeconds)
    }

    Write-Host "==> $(Get-StepLabel)  Merging the measurements"
    $merged = Join-Path $paths.Work "$GameId.profdata"
    & $Toolchain.Profdata merge "-output=$merged" @($raw | ForEach-Object FullName) | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "llvm-profdata merge failed ($LASTEXITCODE)." }
    return $merged
}

$script:step = 0
function Get-StepLabel { $script:step++; return "$script:step/$script:stepCount" }

New-Item -ItemType Directory -Force $paths.Logs | Out-Null
Start-Transcript -LiteralPath (Join-Path $paths.Logs 'build-game.log') | Out-Null
$started = Get-Date
try {
    $heading = if ($Optimize) { 'optimizing the game for this PC' } else { 'building the game from your disc' }
    Write-Host "Def Jam: Fight for NY - $heading" -ForegroundColor Yellow
    Write-Host ''
    $script:stepCount = if ($Optimize) { 7 } else { 4 }

    $toolchain = @{
        Clang  = Join-Path $paths.Toolchain 'bin\clang.exe'
        CMake  = Join-Path $paths.Toolchain 'bin\cmake.exe'
        Ninja  = Join-Path $paths.Toolchain 'bin\ninja.exe'
        Python = Join-Path $paths.Toolchain 'python\bin\python.exe'
    }
    if ($Optimize) { $toolchain.Profdata = Join-Path $paths.Toolchain 'bin\llvm-profdata.exe' }
    $dolrecomp = Join-Path $paths.Bin 'dolrecomp.exe'
    $missing = @(@($toolchain.Values) + $dolrecomp | Where-Object { -not (Test-Path -LiteralPath $_) })
    if ($missing) { Stop-Build "The installation is incomplete; reinstall the game. Missing:`n  $($missing -join "`n  ")" }

    $haveGame = Test-Path -LiteralPath (Join-Path $paths.Game 'sys\main.dol')
    if ($Iso) {
        $Iso = (Resolve-Path -LiteralPath $Iso).Path
        $null = Test-DiscImage $Iso
    }
    elseif (-not $haveGame) {
        Stop-Build 'No disc image given and no extracted game found. Choose your Def Jam: Fight for NY .iso.'
    }

    # Extracted game ~1.4 GB, work files up to ~3 GB while compiling, plus the shader cache.
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($app))
    $needGb = if ($Iso) { 6 } else { 4 }
    if ($Optimize) { $needGb += 2 }  # the measuring build beside the real one
    if ($drive.AvailableFreeSpace / 1GB -lt $needGb) {
        Stop-Build ("Not enough free space on {0}: {1:N1} GB free, about {2} GB needed while building." -f
            $drive.Name, ($drive.AvailableFreeSpace / 1GB), $needGb)
    }
    if (-not (Test-Compiler $toolchain.Clang)) {
        Stop-Build @"
The bundled C compiler cannot compile a trivial program.

An antivirus may have quarantined part of the toolchain folder (clang and lld are often
flagged by mistake). Restore it from quarantine, or reinstall the game.
"@
    }
    if ($Jobs -le 0) { $Jobs = Get-ModuleBuildJobs }

    # A reinstall over a built game (an update of the runtime, launcher or settings) keeps the
    # compiled game when nothing it is made from has changed, instead of spending minutes
    # building the same one again.
    $keepModule = -not $Iso -and -not $Optimize -and (Test-ModuleUpToDate)
    if ($keepModule) { $script:stepCount = 2 }

    $stamp = Get-ProfileStamp @($dolrecomp, $toolchain.Clang,
        (Join-Path $paths.Config "recomp\$GameId.flags"), (Join-Path $paths.Config "recomp\$GameId.regions"))
    if ($keepModule) {
        Write-Host "==> $(Get-StepLabel)  The game's code has not changed: keeping the compiled game"
    }
    else {
        if ($Iso) {
            Write-Host "==> $(Get-StepLabel)  Extracting the disc"
            if (Test-Path -LiteralPath $paths.Game) { Remove-Item -Recurse -Force -LiteralPath $paths.Game }
            & $dolrecomp extract $Iso $paths.Game 2>&1 | Out-Host
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $paths.Game 'sys\main.dol'))) {
                Stop-Build "Extracting the disc failed (dolrecomp exit $LASTEXITCODE). See the messages above."
            }
        }
        else {
            Write-Host "==> $(Get-StepLabel)  Using the game already extracted"
        }

        Write-Host "==> $(Get-StepLabel)  Recompiling the game's code"
        $flags = Get-RecompilerFlags -FlagsFile (Join-Path $paths.Config "recomp\$GameId.flags") `
            -RegionsFile (Join-Path $paths.Config "recomp\$GameId.regions")
        $generated = Invoke-Recompiler -DolRecomp $dolrecomp -Dol (Join-Path $paths.Game 'sys\main.dol') `
            -Flags $flags -WorkDir $paths.Work -Jobs $Jobs

        if ($Optimize) {
            Write-Host "==> $(Get-StepLabel)  Compiling a measuring version of the game (several minutes, $Jobs jobs)"
            $pgoProfile = Invoke-ProfileTraining -Toolchain $toolchain -Generated $generated
            Write-Host "==> $(Get-StepLabel)  Compiling the optimized game (several minutes, $Jobs jobs)"
        }
        else {
            $pgoProfile = Get-SavedProfile $stamp
            $how = if ($pgoProfile) { ', optimized with the profile from an earlier run' } else { '' }
            Write-Host "==> $(Get-StepLabel)  Compiling (the long part: several minutes, $Jobs jobs$how)"
        }
        $dll = Invoke-ModuleBuild -Toolchain $toolchain -ModuleSource $paths.ModuleSource `
            -GeneratedDir $generated -BuildDir (Join-Path $paths.Work 'build') -GameId $GameId -Jobs $Jobs `
            -PgoProfile $pgoProfile
        # Only a finished build replaces the module, so a failure leaves the game playable.
        New-Item -ItemType Directory -Force $paths.Module | Out-Null
        Copy-Item -LiteralPath $dll $paths.Module -Force
        if ($Optimize) {
            Copy-Item -LiteralPath $pgoProfile $profilePaths.Profile -Force
            $stamp | Set-Content -Encoding ascii -LiteralPath $profilePaths.Stamp
        }
        Get-ModuleStamp $stamp $pgoProfile | Set-Content -Encoding ascii -LiteralPath $profilePaths.ModuleStamp
    }

    Write-Host "==> $(Get-StepLabel)  Preparing settings"
    Initialize-UserDirectory -UserDir $paths.UserData -ConfigDir $paths.Config -GameId $GameId
    Remove-Item -Recurse -Force -LiteralPath $paths.Work -ErrorAction SilentlyContinue

    Write-Host ''
    Write-Host ("Done in {0:mm\:ss}. Start the game from the Def Jam: Fight for NY shortcut." -f ((Get-Date) - $started)) -ForegroundColor Green
}
catch {
    Stop-Build "The build failed: $($_.Exception.Message)"
}
finally {
    try { Stop-Transcript | Out-Null } catch { }
}
exit 0
