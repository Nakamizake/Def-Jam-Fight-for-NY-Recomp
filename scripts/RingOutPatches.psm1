<#
.SYNOPSIS
    Applies and saves the local patch series of lib/RingOut (patches/RingOut/*.patch).

.DESCRIPTION
    The series is ordered by file name and applied on top of the submodule's HEAD. To find
    out how much of it a working tree already has, the tree is compared with "HEAD plus the
    first N patches" built in a scratch git index (a copy of the real one, so unchanged files
    are not re-hashed). Checking the series as a whole, rather than reverse-applying each
    patch on its own, keeps working when two patches touch neighbouring lines. Nothing in
    the submodule is modified while checking.
#>

function Invoke-Git {
    param([string] $Repository, [string[]] $Arguments, [string] $IndexFile)
    $previousIndex = $env:GIT_INDEX_FILE
    $previousPreference = $ErrorActionPreference
    # Windows PowerShell turns native stderr into errors; git's warnings must not abort us.
    $ErrorActionPreference = 'Continue'
    if ($IndexFile) { $env:GIT_INDEX_FILE = $IndexFile }
    try {
        $output = & git -C $Repository -c core.safecrlf=false @Arguments 2>&1
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = @($output | ForEach-Object { "$_" })
        }
    } finally {
        $ErrorActionPreference = $previousPreference
        if ($IndexFile) {
            if ($null -eq $previousIndex) { Remove-Item Env:GIT_INDEX_FILE } else { $env:GIT_INDEX_FILE = $previousIndex }
        }
    }
}

function Get-PatchSeries([string] $PatchDirectory) {
    @(Get-ChildItem $PatchDirectory -Filter *.patch -ErrorAction SilentlyContinue | Sort-Object Name)
}

function New-ScratchIndex([string] $Stack) {
    $realIndex = (Invoke-Git $Stack @('rev-parse', '--path-format=absolute', '--git-path', 'index')).Output[0]
    $scratch = Join-Path ([IO.Path]::GetTempPath()) "ringout-series-$PID.index"
    if (Test-Path $realIndex) { Copy-Item $realIndex $scratch -Force } else { Remove-Item $scratch -ErrorAction SilentlyContinue }
    $result = Invoke-Git $Stack @('read-tree', '--reset', 'HEAD') $scratch
    if ($result.ExitCode -ne 0) { throw "git read-tree failed in ${Stack}:`n$($result.Output -join "`n")" }
    $scratch
}

function Add-PatchToIndex([string] $Stack, [string] $IndexFile, [IO.FileInfo] $Patch) {
    $result = Invoke-Git $Stack @('apply', '--cached', '--ignore-whitespace', '--whitespace=nowarn', $Patch.FullName) $IndexFile
    if ($result.ExitCode -ne 0) {
        throw "$($Patch.Name) does not apply on top of the patches before it:`n$($result.Output -join "`n")"
    }
}

function Test-WorkingTreeMatchesIndex([string] $Stack, [string] $IndexFile) {
    Invoke-Git $Stack @('update-index', '-q', '--refresh') $IndexFile | Out-Null
    (Invoke-Git $Stack @('diff-files', '--quiet') $IndexFile).ExitCode -eq 0
}

<#
.SYNOPSIS
    Applies whatever part of the series the submodule does not have yet.
.DESCRIPTION
    Throws if the working tree matches no prefix of the series, i.e. it has changes of its
    own: those should be saved with Save-RingOutPatch (scripts/save-ringout-patch.ps1) first.
#>
function Sync-RingOutPatches {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Stack, [Parameter(Mandatory)] [string] $PatchDirectory)

    $patches = Get-PatchSeries $PatchDirectory
    $index = New-ScratchIndex $Stack
    try {
        $applied = if (Test-WorkingTreeMatchesIndex $Stack $index) { 0 } else { -1 }
        for ($i = 0; $i -lt $patches.Count; $i++) {
            Add-PatchToIndex $Stack $index $patches[$i]
            if (Test-WorkingTreeMatchesIndex $Stack $index) { $applied = $i + 1 }
        }
    } finally {
        Remove-Item $index -ErrorAction SilentlyContinue
    }
    if ($applied -lt 0) {
        throw "lib/RingOut has changes that are not part of patches/RingOut. Save them with " +
            "scripts/save-ringout-patch.ps1, or build with -NoPatch to use the tree as it is."
    }
    for ($i = $applied; $i -lt $patches.Count; $i++) {
        $result = Invoke-Git $Stack @('apply', '--ignore-whitespace', '--whitespace=nowarn', $patches[$i].FullName)
        if ($result.ExitCode -ne 0) { throw "Failed to apply $($patches[$i].Name):`n$($result.Output -join "`n")" }
        Write-Host "Applied RingOut/$($patches[$i].Name)"
    }
}

<#
.SYNOPSIS
    Saves the submodule's changes on top of the series as a patch.
.DESCRIPTION
    With a new name the patch is appended to the series. With the name of the last patch,
    that patch is regenerated, folding the new changes into it. Untracked files that git
    does not ignore are included as new files.
#>
function Save-RingOutPatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Stack,
        [Parameter(Mandatory)] [string] $PatchDirectory,
        [Parameter(Mandatory)] [string] $Name
    )

    $patches = Get-PatchSeries $PatchDirectory
    $target = Join-Path (Resolve-Path $PatchDirectory) "$Name.patch"
    $base = @($patches | Where-Object { $_.FullName -ne $target })
    if ($base.Count -ne $patches.Count -and $patches[-1].FullName -ne $target) {
        throw "Only the last patch of the series ($($patches[-1].Name)) can be regenerated."
    }

    $index = New-ScratchIndex $Stack
    try {
        foreach ($patch in $base) { Add-PatchToIndex $Stack $index $patch }
        $untracked = (Invoke-Git $Stack @('ls-files', '--others', '--exclude-standard')).Output
        if ($untracked) {
            Invoke-Git $Stack (@('add', '--intent-to-add', '--') + $untracked) $index | Out-Null
        }
        Invoke-Git $Stack @('update-index', '-q', '--refresh') $index | Out-Null
        $stat = (Invoke-Git $Stack @('diff-files', '--stat') $index).Output
        if (-not $stat) { throw 'The submodule has no changes on top of the series.' }
        $result = Invoke-Git $Stack @('diff-files', '-p', '--binary', "--output=$target") $index
        if ($result.ExitCode -ne 0) { throw "git diff failed:`n$($result.Output -join "`n")" }
    } finally {
        Remove-Item $index -ErrorAction SilentlyContinue
    }
    Write-Host "Saved $target"
    $stat | ForEach-Object { Write-Host "  $_" }
}

Export-ModuleMember -Function Sync-RingOutPatches, Save-RingOutPatch
