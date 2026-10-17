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

function Invoke-InVsDevEnv {
    <#
    .SYNOPSIS
        Runs a cmd.exe command line with the x64 MSVC environment loaded. Throws on failure.
    #>
    param([Parameter(Mandatory)] [string] $CommandLine)

    $vcvars = Get-VcVarsPath
    & cmd.exe /d /c "call `"$vcvars`" -vcvars_ver=$script:MsvcToolset >nul && $CommandLine"
    if ($LASTEXITCODE -ne 0) { throw "Command failed ($LASTEXITCODE): $CommandLine" }
}

Export-ModuleMember -Function Invoke-InVsDevEnv
