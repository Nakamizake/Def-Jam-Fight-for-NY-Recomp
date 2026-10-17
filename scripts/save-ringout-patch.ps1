<#
.SYNOPSIS
    Saves the changes made in lib/RingOut as a patch in patches/RingOut/.

.DESCRIPTION
    lib/RingOut is never committed to; every local change lives in the patch series that
    build-tools.ps1 applies. After editing the submodule in place, run this to turn the
    edits (everything on top of the existing series, new files included) into a patch.

    Pass a new name to append a patch, or the name of the last patch to fold the edits
    into it.

.EXAMPLE
    .\scripts\save-ringout-patch.ps1 0008-faster-texture-decode
    .\scripts\save-ringout-patch.ps1 0007-diagnostic-reporter   # regenerate the last one
#>
[CmdletBinding()]
param([Parameter(Mandatory)] [string] $Name)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RingOutPatches.psm1') -Force

$repoRoot = Split-Path -Parent $PSScriptRoot
Save-RingOutPatch -Stack (Join-Path $repoRoot 'lib\RingOut') `
    -PatchDirectory (Join-Path $repoRoot 'patches\RingOut') -Name ($Name -replace '\.patch$', '')
