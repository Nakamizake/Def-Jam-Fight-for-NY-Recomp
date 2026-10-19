<#
.SYNOPSIS
    Plays Def Jam: Fight for NY on its own, from a cold boot into back-to-back 2v2 fights,
    through ModernGekko's automation directory. Used to train the PGO profile without
    savestates (savestates hold the game's memory and cannot be shipped).

.DESCRIPTION
    The runtime runs with --unattended: the player's keyboard and pads are ignored, the
    settings menu is off and a banner explains what is happening. This module sends pad
    presses and reads three guest variables to know where the game is:

      PhaseAddress  0x00006400 start-up, 0x01002A00 front-end menus, 0x01003300 in a match
      IntroAddress  0 while the start-up memory card dialogs are up; after them it changes
                    every few frames, so it tells nothing about the later screens
      FightAddress  in a match: 1 while fighting (and loading a rematch), 0 on the match
                    summary and the rematch question

    They are static addresses in main.dol, so they hold for every copy of GNWE69. The
    front-end screens have no such marker, so that part of the route is a timed sequence,
    and a session that does not reach a match in time is restarted by the caller.

    Route (fresh memory card, so the dialogs are always the same two): A on the autosave
    warning, B to continue without loading options, Start through the movie and the title,
    Battle > Team match > standard rules, user IDs from slot A with no ID for player 1,
    four different fighters (the three CPUs cannot repeat one, so each moves its cursor
    first), confirm the teams and the venue. After a match: A on the summary, then Left and
    A for "Rematch? Yes".
#>

$ErrorActionPreference = 'Stop'
# Initialize-UserDirectory. Without -Force: forcing a reload here would unload the copy the
# calling script imported, and its GameBuild functions would vanish mid-build.
Import-Module (Join-Path $PSScriptRoot 'GameBuild.psm1')

# Hex literals above 0x7FFFFFFF parse as negative Int32 in Windows PowerShell.
$PhaseAddress = [Convert]::ToUInt32('802FE720', 16)
$IntroAddress = [Convert]::ToUInt32('804404E8', 16)
$FightAddress = [Convert]::ToUInt32('802EEE18', 16)
$PhaseStartup = 0x00006400
$PhaseMenus = 0x01002A00
$PhaseMatch = 0x01003300

# --------------------------------------------------------------------- automation client

# One automation session: the directory the runtime watches, plus a counter that keeps
# command files in the order they were sent (the runtime processes them by name).
# -TraceDir, when given, receives a screenshot after every step of the menu route.
function New-AutomationSession([Parameter(Mandatory)] [string] $Directory, [string] $TraceDir = '') {
    $commands = Join-Path $Directory 'commands'
    if (Test-Path -LiteralPath $Directory) { Remove-Item -Recurse -Force -LiteralPath $Directory }
    New-Item -ItemType Directory -Force $commands, (Join-Path $Directory 'reads') | Out-Null
    if ($TraceDir) { New-Item -ItemType Directory -Force $TraceDir | Out-Null }
    return [pscustomobject]@{ Directory = $Directory; Commands = $commands; Counter = 0; TraceDir = $TraceDir; TraceCount = 0 }
}

# Drops a command file into commands/ atomically (written aside, then moved in).
function Send-AutomationCommand($Session, [string] $Name, [string[]] $Lines) {
    $Session.Counter++
    $file = '{0:D7}-{1}.txt' -f $Session.Counter, $Name
    $temp = Join-Path $Session.Directory "$file.tmp"
    [IO.File]::WriteAllText($temp, (($Lines -join "`n") + "`n"), [Text.Encoding]::ASCII)
    Move-Item -LiteralPath $temp -Destination (Join-Path $Session.Commands $file)
}

# status.txt as a hashtable, or $null before the runtime has written one.
function Read-AutomationStatus($Session) {
    $path = Join-Path $Session.Directory 'status.txt'
    $status = @{}
    try { $lines = [IO.File]::ReadAllLines($path) } catch { return $null }
    foreach ($line in $lines) {
        $key, $value = $line -split '=', 2
        if ($key) { $status[$key] = $value }
    }
    return $status
}

# Presses pad buttons on port 0 for a number of frames, e.g. Send-Pad $s 'a' or
# Send-Pad $s @{ main_x = '1' } 20. The runtime releases them afterwards.
function Send-Pad($Session, $Buttons, [int] $Frames = 6) {
    $lines = @('command=pad_frames', 'port=0', "frames=$Frames")
    if ($Buttons -is [hashtable]) { $lines += @($Buttons.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) }
    else { $lines += @($Buttons | ForEach-Object { "$_=1" }) }
    Send-AutomationCommand $Session 'pad' $lines
}

# The banner drawn over the game in unattended mode; "`n" starts a new line.
function Set-AutomationBanner($Session, [string] $Text) {
    Send-AutomationCommand $Session 'banner' @('command=banner', "text=$($Text -replace "`r?`n", '\n')")
}

# Zeroes the counts of a module built for PGO training (see build-game.ps1 -Optimize).
function Reset-ModuleProfile($Session) {
    Send-AutomationCommand $Session 'profile-reset' @('command=profile_reset')
}

function Stop-AutomationRuntime($Session) {
    Send-AutomationCommand $Session 'stop' @('command=stop')
}

# Reads a big-endian u32 from guest memory, or $null if the runtime did not answer in time
# (still booting, or gone).
function Read-GuestU32($Session, [uint32] $Address, [int] $TimeoutMs = 3000) {
    $out = Join-Path $Session.Directory ('reads\{0:X8}-{1}.bin' -f $Address, ($Session.Counter + 1))
    Send-AutomationCommand $Session 'read' @('command=read_memory', ('address=0x{0:X8}' -f $Address), 'size=4', "path=$out")
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $bytes = [IO.File]::ReadAllBytes($out)
            if ($bytes.Length -eq 4) {
                Remove-Item -LiteralPath $out -ErrorAction SilentlyContinue
                return ([uint32]$bytes[0] -shl 24) -bor ([uint32]$bytes[1] -shl 16) -bor ([uint32]$bytes[2] -shl 8) -bor [uint32]$bytes[3]
            }
        }
        catch { }
        Start-Sleep -Milliseconds 50
    }
    return $null
}

# Polls until & $Condition returns true; false after $Seconds.
function Wait-Until([scriptblock] $Condition, [double] $Seconds, [int] $PollMs = 500) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (& $Condition) { return $true }
        Start-Sleep -Milliseconds $PollMs
    }
    return $false
}

# ------------------------------------------------------------------------------- route

# A step of the front-end route: buttons pressed together, then a pause in seconds.
function Step([string[]] $Buttons, [double] $Pause) { [pscustomobject]@{ Buttons = $Buttons; Pause = $Pause } }

$MenuRoute = @(
    (Step 'dpad_right' 1.0), (Step 'a' 2.5)              # main menu: Story > Battle
    (Step 'dpad_right' 1.0), (Step 'a' 2.5)              # match type: One on One > Team
    (Step 'a' 2.5)                                       # rules: standard
    (Step 'a' 3.0)                                       # load user IDs from slot A
    (Step 'start' 1.5), (Step 'a' 1.5), (Step 'a' 3.0)   # player 1: no user ID, continue
    (Step 'a' 1.2), (Step 'a' 1.5)                       # player 1: first fighter, outfit
    (Step 'dpad_right' 0.6), (Step 'a' 1.2), (Step 'a' 1.5)                      # CPU 2
    (Step 'dpad_right' 0.4), (Step 'dpad_right' 0.6), (Step 'a' 1.2), (Step 'a' 1.5)  # CPU 3
    (Step 'dpad_down' 0.6), (Step 'a' 1.2), (Step 'a' 2.0)                       # CPU 4
)

# Saves a screenshot named after a route step when the session traces its route.
function Save-TraceShot($Session, [string] $Name) {
    if (-not $Session.TraceDir) { return }
    $Session.TraceCount++
    $path = Join-Path $Session.TraceDir ('{0:D3}-{1}.png' -f $Session.TraceCount, $Name)
    Send-AutomationCommand $Session 'screenshot' @('command=screenshot', "path=$path")
}

# From power-on to the first match. Returns $true once a match is loading, $false when it
# times out or the game stops answering.
function Invoke-BootToMatch($Session, [int] $TimeoutSeconds = 240) {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $phase = { Read-GuestU32 $Session $PhaseAddress }

    # Start-up dialogs: A for the autosave warning, B to skip loading options. Alternating
    # keeps it right if a press lands on a screen still fading in.
    if (-not (Wait-Until { $null -ne (& $phase) } 90)) { return $false }
    $next = 'a'
    while ([DateTime]::UtcNow -lt $deadline) {
        $intro = Read-GuestU32 $Session $IntroAddress
        if ($null -ne $intro -and $intro -ne 0) { break }
        Send-Pad $Session $next
        $next = if ($next -eq 'a') { 'b' } else { 'a' }
        Start-Sleep -Seconds 2
    }

    # Logos (cannot be skipped), the movie and the title (which ignores Start for its first
    # seconds): Start every few seconds until the front end is up. The phase turns to menus
    # about 2.3 s after the Start that leaves the title, so the spacing keeps a Start from
    # landing on the main menu, where it would open Story mode.
    $misses = 0
    while ([DateTime]::UtcNow -lt $deadline) {
        $current = & $phase
        if ($null -eq $current) {
            # Unanswered for ~10 s: the game hung (skipping the intro movie can, rarely).
            # The caller restarts it.
            if (++$misses -ge 3) { return $false }
            continue
        }
        $misses = 0
        if ($current -eq $PhaseMenus) { break }
        Save-TraceShot $Session 'start'
        Send-Pad $Session 'start'
        Start-Sleep -Seconds 5
    }
    if ((& $phase) -ne $PhaseMenus) { return $false }

    Start-Sleep -Seconds 3  # the main menu slides in
    Save-TraceShot $Session 'main-menu'
    $index = 0
    foreach ($step in $MenuRoute) {
        Send-Pad $Session $step.Buttons
        Start-Sleep -Seconds $step.Pause
        Save-TraceShot $Session ('route{0:D2}-{1}' -f (++$index), ($step.Buttons -join '+'))
    }
    # Teams and venue only need confirming; extra presses are harmless until the match loads.
    # Every fourth press moves instead: if a press of the route was lost, a CPU cursor can
    # rest on a fighter already taken, where A does nothing. Moving is harmless elsewhere
    # (any outfit, team slot or venue will do).
    $nudges = @('dpad_right', 'dpad_down')
    for ($i = 0; $i -lt 30 -and [DateTime]::UtcNow -lt $deadline; $i++) {
        if ((& $phase) -eq $PhaseMatch) { return $true }
        $button = if ($i % 4 -eq 3) { $nudges[[math]::Floor($i / 4) % 2] } else { 'a' }
        Send-Pad $Session $button
        Start-Sleep -Milliseconds 1500
        Save-TraceShot $Session 'confirm'
    }
    return (& $phase) -eq $PhaseMatch
}

# Fights back to back until $Seconds of fighting have been played, calling & $OnProgress
# with the seconds so far now and then. Returns the seconds of fighting played; it stops
# early if the game leaves the match (a rematch refused) or stops answering.
# -ResetProfile zeroes a training module's counts once the first fight is on, so boot,
# intro movie and menus do not weigh in the profile.
function Invoke-Fights($Session, [double] $Seconds, [scriptblock] $OnProgress = {}, [switch] $ResetProfile) {
    $attacks = @('a', 'b', 'x', 'y', 'b', 'x', 'y', 'a')
    $directions = @(@{ main_x = '1' }, @{ main_x = '-1' }, @{ main_y = '1' }, @{ main_y = '-1' })
    $random = [Random]::new()
    $fought = 0.0
    $lastTick = [DateTime]::UtcNow
    $lastReport = $lastTick
    $missed = 0
    while ($fought -lt $Seconds) {
        $phase = Read-GuestU32 $Session $PhaseAddress
        $now = [DateTime]::UtcNow
        $elapsed = ($now - $lastTick).TotalSeconds
        $lastTick = $now
        if ($null -eq $phase) {
            if (++$missed -ge 10) { break }
            continue
        }
        $missed = 0
        if ($phase -ne $PhaseMatch) { break }
        if ((Read-GuestU32 $Session $FightAddress) -eq 1) {
            if ($ResetProfile) { Reset-ModuleProfile $Session; $ResetProfile = $false }
            $fought += $elapsed
            # Walk somewhere now and then, otherwise throw attacks; A also closes the
            # tutorial pop-ups the game shows during the first fights.
            if ($random.Next(4) -eq 0) { Send-Pad $Session $directions[$random.Next($directions.Count)] (20 + $random.Next(30)) }
            else { Send-Pad $Session $attacks[$random.Next($attacks.Count)] }
            Start-Sleep -Milliseconds 250
        }
        else {
            # Summary (A continues) or "Rematch?" (No is preselected: Left, then A).
            Send-Pad $Session 'dpad_left'
            Start-Sleep -Milliseconds 600
            Send-Pad $Session 'a'
            Start-Sleep -Milliseconds 1200
        }
        if (($now - $lastReport).TotalSeconds -ge 5) { & $OnProgress $fought; $lastReport = $now }
    }
    return $fought
}

# ----------------------------------------------------------------------------- session

# Runs the game unattended until $FightSeconds of fighting have been played, restarting it
# (with a fresh memory card) when a boot does not reach a match. Every game process is
# closed normally, so an instrumented module writes its profile. Returns the seconds of
# fighting played.
function Invoke-AutoPlay {
    param(
        [Parameter(Mandatory)] [string] $Runner,
        [Parameter(Mandatory)] [string] $GameRoot,
        [Parameter(Mandatory)] [string] $Module,
        # Throwaway user directory: wiped on every attempt.
        [Parameter(Mandatory)] [string] $UserDir,
        [Parameter(Mandatory)] [string] $ConfigDir,
        [Parameter(Mandatory)] [string] $AutomationDir,
        [double] $FightSeconds = 240,
        [int] $MaxAttempts = 3,
        [string] $Title = 'Def Jam: Fight for NY',
        # Banner heading and the lines under it; '{0}' in -BannerBody becomes the minutes left.
        [string] $BannerHeading = 'RUNNING ON ITS OWN',
        [string] $BannerBody = 'About {0} min left. Keyboard and controllers are ignored; close this window to stop.',
        [string] $LogFile = '',
        # Screenshots of every route step go to <TraceDir>\attempt-<n>; none when empty.
        [string] $TraceDir = '',
        # For a module built for PGO training: count the fights only (see Invoke-Fights).
        [switch] $FightsOnlyProfile
    )
    $fought = 0.0
    for ($attempt = 1; $attempt -le $MaxAttempts -and $fought -lt $FightSeconds; $attempt++) {
        Write-Host "    attempt $attempt"
        if (Test-Path -LiteralPath $UserDir) { Remove-Item -Recurse -Force -LiteralPath $UserDir }
        Initialize-UserDirectory -UserDir $UserDir -ConfigDir $ConfigDir -GameId 'GNWE69'
        # Windowed and muted; the player's own settings are not touched.
        $ini = Join-Path $UserDir 'Config\Dolphin.ini'
        Set-IniValues $ini @{ 'Display' = @{ Fullscreen = 'False' }; 'DSP' = @{ Volume = '0' } }

        $attemptTrace = if ($TraceDir) { Join-Path $TraceDir "attempt-$attempt" } else { '' }
        $session = New-AutomationSession $AutomationDir $attemptTrace
        $arguments = @('--game', $GameRoot, '--module', $Module, '--user-dir', $UserDir, '--title', $Title,
            '--automation-dir', $AutomationDir, '--unattended')
        $quoted = $arguments | ForEach-Object { '"{0}"' -f $_ }
        # -NoNewWindow shares this console instead of opening one. Not -WindowStyle Hidden:
        # that start-up flag also hides the game's own window, banner included.
        $startArgs = @{ FilePath = $Runner; ArgumentList = $quoted; PassThru = $true; NoNewWindow = $true }
        if ($LogFile) { $startArgs.RedirectStandardError = "$LogFile.$attempt.err"; $startArgs.RedirectStandardOutput = "$LogFile.$attempt.out" }
        $game = Start-Process @startArgs
        try {
            $minutesLeft = { [math]::Max(1, [math]::Ceiling(($FightSeconds - $fought) * 1.4 / 60)) }
            Set-AutomationBanner $session ("$BannerHeading`n" + ($BannerBody -f (& $minutesLeft)))
            if (-not (Invoke-BootToMatch $session)) {
                Write-Host '    did not reach a match; restarting the game'
                continue
            }
            Write-Host '    in a match'
            $fought += Invoke-Fights $session ($FightSeconds - $fought) {
                param($soFar)
                Set-AutomationBanner $session ("$BannerHeading`n" + ($BannerBody -f [math]::Max(1, [math]::Ceiling(($FightSeconds - $fought - $soFar) * 1.4 / 60))))
            } -ResetProfile:$FightsOnlyProfile
            Write-Host ('    {0:N0} s of fighting so far' -f $fought)
        }
        finally {
            if (-not $game.HasExited) {
                Stop-AutomationRuntime $session
                if (-not $game.WaitForExit(30000)) { $game.Kill(); $game.WaitForExit() }
            }
        }
    }
    return $fought
}

# Sets ini values (section -> key -> value) in a file, adding sections and keys as needed.
function Set-IniValues([string] $Path, [hashtable] $Values) {
    $lines = [Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $Path) { $lines.AddRange([string[]][IO.File]::ReadAllLines($Path)) }
    foreach ($section in $Values.Keys) {
        foreach ($key in $Values[$section].Keys) {
            $value = $Values[$section][$key]
            $start = $lines.IndexOf("[$section]")
            if ($start -lt 0) { $lines.Add("[$section]"); $lines.Add("$key = $value"); continue }
            $end = $start + 1
            while ($end -lt $lines.Count -and -not $lines[$end].StartsWith('[')) { $end++ }
            $found = $false
            for ($i = $start + 1; $i -lt $end; $i++) {
                if (($lines[$i] -split '=', 2)[0].Trim() -eq $key) { $lines[$i] = "$key = $value"; $found = $true; break }
            }
            if (-not $found) { $lines.Insert($end, "$key = $value") }
        }
    }
    New-Item -ItemType Directory -Force (Split-Path -Parent $Path) | Out-Null
    [IO.File]::WriteAllLines($Path, [string[]]$lines, [Text.UTF8Encoding]::new($false))
}

Export-ModuleMember -Function Invoke-AutoPlay, Invoke-BootToMatch, Invoke-Fights, New-AutomationSession,
    Send-AutomationCommand, Send-Pad, Reset-ModuleProfile, Read-GuestU32, Set-AutomationBanner, Stop-AutomationRuntime, Read-AutomationStatus
