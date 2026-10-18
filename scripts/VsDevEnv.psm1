<#
    Helpers to run commands inside the Visual Studio developer environment
    (MSVC, CMake and the Ninja bundled with Visual Studio).
#>

$script:MsvcToolset = '14.44'

function Get-VcVarsPath {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path $vswhere) {
        $installPath = & $vswhere -latest -products * `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if ($installPath) {
            $candidate = Join-Path $installPath 'VC\Auxiliary\Build\vcvars64.bat'
            if (Test-Path $candidate) { return $candidate }
        }
    }
    throw 'Visual Studio 2022 with the C++ workload was not found.'
}

# MSVC on a localized install translates the line /showIncludes prints before each header
# (in Portuguese, an accented "Observacao: incluindo arquivo:") and writes it in the console's
# code page. CMake records that line once, at configure time, and Ninja then matches every
# compile's output against it byte for byte to learn which headers an object depends on. A
# build run under another code page than its configure records no dependencies, and later
# header edits then leave stale objects behind. So every command runs under UTF-8.
$script:CodePage = 65001

function Invoke-InVsDevEnv {
    <#
    .SYNOPSIS
        Runs a cmd.exe command line with the x64 MSVC environment loaded. Throws on failure.
    #>
    param([Parameter(Mandatory)] [string] $CommandLine)

    $vcvars = Get-VcVarsPath
    # chcp changes the code page of the whole console, so put the caller's back afterwards.
    # (chcp prints e.g. "Active code page: 850", translated: keep the digits.)
    $previousCodePage = (& cmd.exe /d /c chcp) -replace '\D', ''
    try {
        & cmd.exe /d /c "chcp $script:CodePage >nul && call `"$vcvars`" -vcvars_ver=$script:MsvcToolset >nul && $CommandLine"
        if ($LASTEXITCODE -ne 0) { throw "Command failed ($LASTEXITCODE): $CommandLine" }
    }
    finally {
        if ($previousCodePage -and [int]$previousCodePage -ne $script:CodePage) {
            & cmd.exe /d /c "chcp $previousCodePage >nul"
        }
    }
}

Export-ModuleMember -Function Invoke-InVsDevEnv
