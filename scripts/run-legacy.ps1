<#
.SYNOPSIS
    Runs the game on the previous upstream stack (lib/ModernGekko + the MSVC module).

.DESCRIPTION
    Kept while the RingOut stack is being validated: savestates made here are known-good
    reference points for bisecting RingOut problems. Uses the same userdata/ folder.
#>
[CmdletBinding()]
param([string] $GameId = 'GNWE69')

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$runner = Join-Path $repoRoot 'lib\ModernGekko\build\moderngekko-run.exe'
$module = Get-ChildItem (Join-Path $repoRoot "build\modules\$GameId") -Recurse -Filter "g${GameId}_recomp.dll" |
    Where-Object { $_.Directory.Name -like '0c8fdd3e*-3e84655b1a777643' } | Select-Object -First 1
if (-not (Test-Path $runner) -or -not $module) { throw 'Legacy runtime or module not found.' }
& $runner --game (Join-Path $repoRoot "extracted\$GameId") --module $module.FullName --user-dir (Join-Path $repoRoot 'userdata')
exit $LASTEXITCODE
