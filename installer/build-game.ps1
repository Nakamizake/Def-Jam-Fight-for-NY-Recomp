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

    Everything happens inside the install folder; the work files are deleted at the end.
    A log is kept in logs\build-game.log.

.EXAMPLE
    .\build-game.ps1 -Iso D:\Games\DefJam.iso
    .\build-game.ps1            # rebuilds the module from the already extracted game
#>
[CmdletBinding()]
param(
    # The player's disc image. Optional when game\ was already extracted.
    [string] $Iso = '',
    # Parallel compile jobs; by default as many as cores and memory allow.
    [int] $Jobs = 0,
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

New-Item -ItemType Directory -Force $paths.Logs | Out-Null
Start-Transcript -LiteralPath (Join-Path $paths.Logs 'build-game.log') | Out-Null
$started = Get-Date
try {
    Write-Host 'Def Jam: Fight for NY - building the game from your disc' -ForegroundColor Yellow
    Write-Host ''

    $toolchain = @{
        Clang  = Join-Path $paths.Toolchain 'bin\clang.exe'
        CMake  = Join-Path $paths.Toolchain 'bin\cmake.exe'
        Ninja  = Join-Path $paths.Toolchain 'bin\ninja.exe'
        Python = Join-Path $paths.Toolchain 'python\bin\python.exe'
    }
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

    if ($Iso) {
        Write-Host '==> 1/4  Extracting the disc'
        if (Test-Path -LiteralPath $paths.Game) { Remove-Item -Recurse -Force -LiteralPath $paths.Game }
        & $dolrecomp extract $Iso $paths.Game 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $paths.Game 'sys\main.dol'))) {
            Stop-Build "Extracting the disc failed (dolrecomp exit $LASTEXITCODE). See the messages above."
        }
    }
    else {
        Write-Host '==> 1/4  Using the game already extracted'
    }

    Write-Host "==> 2/4  Recompiling the game's code"
    $flags = Get-RecompilerFlags -FlagsFile (Join-Path $paths.Config "recomp\$GameId.flags") `
        -RegionsFile (Join-Path $paths.Config "recomp\$GameId.regions")
    $generated = Invoke-Recompiler -DolRecomp $dolrecomp -Dol (Join-Path $paths.Game 'sys\main.dol') `
        -Flags $flags -WorkDir $paths.Work -Jobs $Jobs

    Write-Host "==> 3/4  Compiling (the long part: several minutes, $Jobs jobs)"
    $dll = Invoke-ModuleBuild -Toolchain $toolchain -ModuleSource $paths.ModuleSource `
        -GeneratedDir $generated -BuildDir (Join-Path $paths.Work 'build') -GameId $GameId -Jobs $Jobs
    New-Item -ItemType Directory -Force $paths.Module | Out-Null
    Copy-Item -LiteralPath $dll $paths.Module -Force

    Write-Host '==> 4/4  Preparing settings'
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
