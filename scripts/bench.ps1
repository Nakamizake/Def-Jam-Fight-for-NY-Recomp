<#
.SYNOPSIS
    Unattended benchmark: boots the game, gets past the start-up memory card dialogs and
    records emulation speed over time.

.DESCRIPTION
    Drives the runtime through ModernGekko's automation directory (build/automation):
    command files dropped into commands/ press pad buttons, and the runtime writes
    status.txt with fps / speed / frame counters.

    The start-up dialogs run at a steady 60 fps while the intro movies are decoded on the
    emulated CPU, so A is pressed only while the game is presenting at full rate and only
    until the first movie frame rate drop is seen. That gets past the dialogs without
    skipping the intro.

    Results are printed and saved as CSV under build/bench/, together with frame-time
    percentiles for presented frames and VI fields (build/bench/<Label>.render.txt and
    .vblank.txt hold the raw per-frame times). Judge smoothness by those, not the average
    fps: alternating 11 ms / 22 ms frames still average 60 fps.

.EXAMPLE
    .\scripts\bench.ps1
    .\scripts\bench.ps1 -Seconds 120 -Label fp-precise
#>
[CmdletBinding()]
param(
    [int] $Seconds = 90,
    [string] $Label = 'run',
    [int] $MaxDialogPresses = 8,
    # Saves a screenshot every N seconds to build/bench/<Label>/ (0 = off).
    [int] $ScreenshotEvery = 10,
    # Dumps guest memory just before shutdown, e.g. -DumpAddress 0x8028B4A0 -DumpSize 0x4000,
    # to build/bench/<Label>/mem-<address>.bin (compare against main.dol to find SMC writes).
    # Strings (decimal or 0x hex): PowerShell parses 0x8028B4A0 as a negative Int32 literal.
    [string] $DumpAddress = '0',
    [string] $DumpSize = '0',
    # Starts from a savestate instead of a cold boot: no dialog presses, and every sample
    # after the state loads counts towards the average.
    [string] $LoadState = '',
    # Pad buttons pressed after the state is running, comma-separated, one every
    # -PressInterval seconds starting two seconds in (e.g. 'start' to leave a pause menu
    # the state was saved in, or 'start,b,b,y' to also throw a few attacks).
    [string] $PressAfterLoad = '',
    [double] $PressInterval = 1.0,
    # Leaves the game running at the end (e.g. to attach a profiler to a hang).
    [switch] $LeaveRunning,
    # Runs the runtime built with symbols (see build-tools.ps1 -Profiling).
    [switch] $Profiling,
    # Game module DLL override, passed to run.ps1.
    [string] $Module = '',
    # Skips the frame-pacing report. By default the run turns on Dolphin's per-frame time
    # log (GFX.ini LogRenderTimeToFile, restored afterwards) and reports frame-time
    # percentiles: the fps counter averages over a second and hides uneven pacing.
    [switch] $NoFrameTimes,
    # Runs without a window (no swap chain): for a locked screen or a monitor that is off.
    [switch] $Headless,
    # Keeps the game's sound on. Runs are muted by default (volume 0, so audio is still
    # emulated and timed the same) to not disturb whoever is at the PC.
    [switch] $Sound,
    # Reports every video field or presented frame slower than this many milliseconds, with
    # the waits the emulator's threads were in around it (RINGOUT_HITCH_TRACE), to
    # build/bench/<Label>/hitch-*.txt. 0 = off.
    [int] $HitchTraceMs = 0,
    # Extracted game directory override, passed to run.ps1.
    [string] $GameRoot = '',
    # Directory for the files the run writes while the game plays (automation commands and
    # status, the user directory copy, frame logs); defaults to build/. Results still go to
    # build/bench/.
    [string] $WorkDir = '',
    # Renderer override, passed to run.ps1; empty keeps the player's configured backend.
    [ValidateSet('', 'Vulkan', 'D3D', 'D3D12', 'OGL')]
    [string] $Graphics = '',
    # Lifts the speed limit (EmulationSpeed = 0): more emulated time per wall second, e.g. to
    # hunt rare timing bugs. Only the bench copy of the config is changed.
    [switch] $Unthrottled,
    # Extra Dolphin.ini values for this run only, as 'Section.Key=Value', e.g.
    # -Setting 'DSP.DumpAudio=True','Core.DSPHLE=False'. Only the bench copy is changed.
    [string[]] $Setting = @(),
    # Starts with an empty shader cache, so every new shader stalls the GPU thread the way
    # a player's first visit to a scene does.
    [switch] $ColdShaderCache
)

$ErrorActionPreference = 'Stop'
function ConvertTo-UInt32([string] $Text) {
    if ($Text -match '^0x([0-9a-fA-F]+)$') { return [Convert]::ToUInt32($Matches[1], 16) }
    return [uint32]$Text
}
$dumpAddressValue = ConvertTo-UInt32 $DumpAddress
$dumpSizeValue = ConvertTo-UInt32 $DumpSize
$repoRoot = Split-Path -Parent $PSScriptRoot
$workDir = if ($WorkDir) { $WorkDir } else { Join-Path $repoRoot 'build' }
$automationDir = Join-Path $workDir 'automation'
$commandsDir = Join-Path $automationDir 'commands'
$statusFile = Join-Path $automationDir 'status.txt'
$benchDir = Join-Path $repoRoot 'build\bench'

function Read-Status {
    if (-not (Test-Path $statusFile)) { return $null }
    $status = @{}
    foreach ($line in (Get-Content $statusFile -ErrorAction SilentlyContinue)) {
        $key, $value = $line -split '=', 2
        if ($key) { $status[$key] = $value }
    }
    return $status
}

function Send-Command([string] $Name, [string] $Body) {
    $script:commandCounter++
    $file = '{0:D6}-{1}.txt' -f $script:commandCounter, $Name
    $temp = Join-Path $automationDir "$file.tmp"
    $Body | Set-Content -Encoding ascii $temp
    Move-Item $temp (Join-Path $commandsDir $file)  # atomic: the runtime never sees half a file
}

function Send-PadPress([string] $Button, [int] $Frames = 6) {
    Send-Command "press-$Button" "command=pad_frames`nport=0`n$Button=1`nframes=$Frames"
}

# Returns the ini text with $Key = $Value set inside [$Section] (added if missing).
function Set-IniValue([string] $Text, [string] $Section, [string] $Key, [string] $Value) {
    $lines = [Collections.Generic.List[string]]::new()
    if ($Text) { $lines.AddRange([string[]]($Text -split "`r?`n")) }
    $inSection = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i].Trim()
        if ($line -match '^\[(.+)\]$') {
            if ($inSection) { $lines.Insert($i, "$Key = $Value"); return $lines -join "`n" }
            $inSection = $Matches[1] -eq $Section
        }
        elseif ($inSection -and ($line -split '=', 2)[0].Trim() -eq $Key) {
            $lines[$i] = "$Key = $Value"
            return $lines -join "`n"
        }
    }
    if (-not $inSection) { $lines.Add("[$Section]") }
    $lines.Add("$Key = $Value")
    return $lines -join "`n"
}

# Frame-time percentiles (ms) from one of Dolphin's per-frame time logs.
function Get-FrameTimeStats([string] $Path, [int] $Skip) {
    if (-not (Test-Path $Path)) { return $null }
    $times = @(Get-Content $Path | Where-Object { $_.Trim() } | Select-Object -Skip $Skip |
        ForEach-Object { [double]::Parse($_, [Globalization.CultureInfo]::InvariantCulture) })
    if ($times.Count -eq 0) { return $null }
    $sorted = $times | Sort-Object
    $at = { param($q) $sorted[[math]::Min($sorted.Count - 1, [int]($q * $sorted.Count))] }
    # A frame is off pace when it lands more than ~3 ms away from 60 Hz (16.7 ms).
    $offPace = @($times | Where-Object { $_ -lt 13.7 -or $_ -gt 19.7 }).Count
    return [pscustomobject]@{
        Frames = $times.Count; P50 = & $at 0.5; P95 = & $at 0.95; P99 = & $at 0.99
        Max = $sorted[-1]; OffPace = $offPace
    }
}

Remove-Item -Recurse -Force $automationDir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $commandsDir, (Join-Path $benchDir $Label) | Out-Null

# Benchmarks run in a throwaway copy of the player's user directory, refreshed every run:
# a test fight that ends autosaves campaign progress to the memory card, and that must not
# touch the player's real save. Savestates, logs and dumps are not copied.
$playerUserDir = Join-Path $repoRoot 'userdata'
$userDir = Join-Path $workDir 'bench-userdata'
Remove-Item -Recurse -Force $userDir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $userDir | Out-Null
foreach ($item in 'Config', 'GameSettings', 'GC', 'Wii', 'Load', 'Cache', 'config.ini') {
    $source = Join-Path $playerUserDir $item
    if ($ColdShaderCache -and $item -eq 'Cache') { continue }
    if (Test-Path $source) { Copy-Item $source $userDir -Recurse -Force }
}
if ($Unthrottled) {
    $benchIni = Join-Path $userDir 'Config\Dolphin.ini'
    $lines = @(Get-Content $benchIni | Where-Object { $_ -notmatch '^\s*EmulationSpeed\s*=' })
    $core = [array]::IndexOf($lines, '[Core]')
    if ($core -lt 0) { $lines += '[Core]'; $core = $lines.Count - 1 }
    $lines = @($lines[0..$core]) + 'EmulationSpeed = 0' + @($lines | Select-Object -Skip ($core + 1))
    [IO.File]::WriteAllLines($benchIni, [string[]]$lines, [Text.UTF8Encoding]::new($false))
}
if (-not $Sound) {
    $benchIni = Join-Path $userDir 'Config\Dolphin.ini'
    $text = if (Test-Path $benchIni) { [IO.File]::ReadAllText($benchIni) } else { $null }
    [IO.File]::WriteAllText($benchIni, (Set-IniValue $text 'DSP' 'Volume' '0'), [Text.UTF8Encoding]::new($false))
}
foreach ($entry in $Setting) {
    if ($entry -notmatch '^([^.=]+)\.([^=]+)=(.*)$') { throw "-Setting '$entry' is not Section.Key=Value" }
    $benchIni = Join-Path $userDir 'Config\Dolphin.ini'
    $text = if (Test-Path $benchIni) { [IO.File]::ReadAllText($benchIni) } else { $null }
    [IO.File]::WriteAllText($benchIni, (Set-IniValue $text $Matches[1] $Matches[2] $Matches[3]),
        [Text.UTF8Encoding]::new($false))
}

$runArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'run.ps1'),
    '-AutomationDir', $automationDir, '-UserDir', $userDir)
if ($Profiling) { $runArgs += '-Profiling' }
if ($Headless) { $runArgs += @('-ExtraArgs', '--headless') }
if ($Graphics) { $runArgs += @('-Graphics', $Graphics) }
if ($GameRoot) { $runArgs += @('-GameRoot', (Resolve-Path $GameRoot).Path) }
if ($Module) { $runArgs += @('-Module', (Resolve-Path $Module).Path) }
if ($LoadState) {
    $runArgs += @('-LoadState', (Resolve-Path $LoadState).Path)
    $MaxDialogPresses = 0
}
$gfxIni = Join-Path $userDir 'Config\GFX.ini'
$frameLogs = @{
    render = Join-Path $userDir 'Logs\render_times.txt'  # one line per presented frame
    vblank = Join-Path $userDir 'Logs\vblank_times.txt'  # one line per emulated VI field
}
$gfxOriginal = $null
if (-not $NoFrameTimes) {
    if (Test-Path $gfxIni) { $gfxOriginal = [IO.File]::ReadAllText($gfxIni) }
    New-Item -ItemType Directory -Force (Split-Path -Parent $gfxIni) | Out-Null
    [IO.File]::WriteAllText($gfxIni, (Set-IniValue $gfxOriginal 'Settings' 'LogRenderTimeToFile' 'True'),
        [Text.UTF8Encoding]::new($false))
    $frameLogs.Values | Remove-Item -ErrorAction SilentlyContinue
}

$logFile = Join-Path $benchDir "$Label.log"
# A game the player already has open is not ours to close at the end.
$preexistingGames = @(Get-Process moderngekko-run -ErrorAction SilentlyContinue | ForEach-Object Id)
if ($HitchTraceMs -gt 0) { $env:RINGOUT_HITCH_TRACE = $HitchTraceMs }  # inherited by the runtime
$runner = Start-Process powershell -ArgumentList $runArgs -PassThru -WindowStyle Hidden `
    -RedirectStandardError $logFile -RedirectStandardOutput "$logFile.out"
Remove-Item Env:RINGOUT_HITCH_TRACE -ErrorAction SilentlyContinue

$script:commandCounter = 0
$samples = [System.Collections.Generic.List[object]]::new()
$presses = 0
$lastPress = [datetime]::MinValue
$movieStarted = $false
$afterLoadButtons = @($PressAfterLoad -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$afterLoadIndex = 0
$firstRunning = $null
$lastFrames = -1
$frozenSince = $null
$start = Get-Date
try {
    while (((Get-Date) - $start).TotalSeconds -lt $Seconds) {
        Start-Sleep -Milliseconds 1000
        $status = Read-Status
        if (-not $status -or $status.booted -ne '1') { continue }
        $fps = [double]$status.fps
        $elapsed = [int][math]::Round(((Get-Date) - $start).TotalSeconds)
        $samples.Add([pscustomobject]@{
            Seconds = $elapsed; Fps = $fps; Speed = [double]$status.speed; Frames = [long]$status.frame_count
        })
        if ($ScreenshotEvery -gt 0 -and $elapsed % $ScreenshotEvery -eq 0) {
            $shot = Join-Path $benchDir "$Label\$('{0:D3}s.png' -f $elapsed)"
            Send-Command 'screenshot' "command=screenshot`npath=$shot"
        }
        # A frame counter that stops moving means the game hung.
        $frames = [long]$status.frame_count
        if ($frames -eq $lastFrames -and $frames -gt 0) {
            if (-not $frozenSince) { $frozenSince = $elapsed }
            if ($elapsed - $frozenSince -eq 3) { Write-Host "${elapsed}s  FROZEN since ${frozenSince}s (frame $frames)" }
        } else { $frozenSince = $null }
        $lastFrames = $frames
        # Headless runs present nothing, so their fps stays 0: go by emulation speed there.
        $running = $fps -gt 0 -or ($Headless -and [double]$status.speed -gt 0)
        if ($afterLoadIndex -lt $afterLoadButtons.Count -and $running) {
            if (-not $firstRunning) { $firstRunning = Get-Date }
            elseif (((Get-Date) - $firstRunning).TotalSeconds -ge 2 + $afterLoadIndex * $PressInterval) {
                $button = $afterLoadButtons[$afterLoadIndex++]
                Send-PadPress $button
                Write-Host "${elapsed}s  pressed $button (after load)"
            }
        }
        if ($presses -gt 0 -and $fps -lt 40) { $movieStarted = $true }
        $sincePress = ((Get-Date) - $lastPress).TotalSeconds
        if (-not $movieStarted -and $presses -lt $MaxDialogPresses -and $fps -ge 50 -and $sincePress -ge 3) {
            Send-PadPress 'a'
            $presses++
            $lastPress = Get-Date
            Write-Host "${elapsed}s  pressed A (dialog)"
        }
    }
}
finally {
    if ($dumpSizeValue -gt 0) {
        $dump = Join-Path $benchDir ("$Label\mem-{0:X8}.bin" -f $dumpAddressValue)
        Send-Command 'dump' ("command=read_memory`naddress=0x{0:X8}`nsize={1}`npath=$dump" -f $dumpAddressValue, $dumpSizeValue)
        Start-Sleep -Seconds 2
    }
    if (-not $LeaveRunning) {
        Get-Process moderngekko-run -ErrorAction SilentlyContinue | Where-Object { $preexistingGames -notcontains $_.Id } |
            ForEach-Object { $_.CloseMainWindow() | Out-Null }
        Start-Sleep -Seconds 4
        # A process that is already shutting down refuses Stop-Process; that is fine.
        Get-Process moderngekko-run -ErrorAction SilentlyContinue | Where-Object { $preexistingGames -notcontains $_.Id } |
            ForEach-Object { try { $_ | Stop-Process -Force -ErrorAction Stop } catch { } }
    }
    # Put the player's graphics settings back (after the runtime is gone: it may save on exit).
    if (-not $NoFrameTimes) {
        if ($null -ne $gfxOriginal) { [IO.File]::WriteAllText($gfxIni, $gfxOriginal, [Text.UTF8Encoding]::new($false)) }
        else { Remove-Item $gfxIni -ErrorAction SilentlyContinue }
    }
}

$csv = Join-Path $benchDir "$Label.csv"
$samples | Export-Csv -NoTypeInformation $csv
$samples | Format-Table -AutoSize | Out-String | Write-Host

if ($LoadState) {
    # Skip the first seconds: the state load and shader compilation distort them.
    $scene = $samples | Select-Object -Skip 5 | Where-Object { $_.Fps -gt 0 }
    if ($scene) {
        $avg = ($scene | Measure-Object Fps -Average).Average
        $speed = ($scene | Measure-Object Speed -Average).Average
        Write-Host ("[{0}] savestate scene: avg {1:N1} fps, avg speed {2:N1} ({3} samples)" -f $Label, $avg, $speed, $scene.Count)
    }
}
$movie = $samples | Where-Object { -not $LoadState -and $movieStarted -and $_.Fps -lt 40 -and $_.Fps -gt 0 }
if ($movie) {
    $avg = ($movie | Measure-Object Fps -Average).Average
    $speed = ($movie | Measure-Object Speed -Average).Average
    Write-Host ("[{0}] intro movie: avg {1:N1} fps, avg speed {2:N1} ({3} samples)" -f $Label, $avg, $speed, $movie.Count)
}
if (-not $NoFrameTimes) {
    # A savestate run skips its first 5 s (300 frames) like the fps average above.
    $skip = if ($LoadState) { 300 } else { 0 }
    foreach ($kind in 'render', 'vblank') {
        if (-not (Test-Path $frameLogs[$kind])) { continue }
        Copy-Item $frameLogs[$kind] (Join-Path $benchDir "$Label.$kind.txt") -Force
        $stats = Get-FrameTimeStats $frameLogs[$kind] $skip
        if (-not $stats) { continue }
        $what = if ($kind -eq 'render') { 'presented frames' } else { 'VI fields' }
        Write-Host ("[{0}] {1}: p50 {2:N1} / p95 {3:N1} / p99 {4:N1} / max {5:N1} ms, off pace (>3 ms from 16.7) {6} of {7} ({8:P1})" -f
            $Label, $what, $stats.P50, $stats.P95, $stats.P99, $stats.Max, $stats.OffPace, $stats.Frames,
            ($stats.OffPace / $stats.Frames))
    }
}
# The next run starts from a fresh user directory: keep the crash reports with the run's results.
$crashReports = @(Get-ChildItem (Join-Path $userDir 'Diagnostics') -Filter 'crash-*.txt' -ErrorAction SilentlyContinue)
if ($crashReports) {
    $crashDir = Join-Path $benchDir $Label
    New-Item -ItemType Directory -Force $crashDir | Out-Null
    $crashReports | Copy-Item -Destination $crashDir -Force
    Write-Host ("[{0}] crash reports: {1} in {2}" -f $Label, $crashReports.Count, $crashDir)
}
if ($HitchTraceMs -gt 0) {
    $hitchReports = @(Get-ChildItem (Join-Path $userDir 'Diagnostics') -Filter 'hitch-*.txt' -ErrorAction SilentlyContinue)
    if ($hitchReports) {
        $hitchDir = Join-Path $benchDir $Label
        $hitchReports | Copy-Item -Destination $hitchDir -Force
    }
    Write-Host ("[{0}] hitch reports (over {1} ms): {2}{3}" -f $Label, $HitchTraceMs, $hitchReports.Count,
        $(if ($hitchReports) { " in $hitchDir" } else { '' }))
}
Get-Content $logFile | Select-String 'shutdown' | ForEach-Object { Write-Host $_ }
Write-Host "CSV: $csv"
