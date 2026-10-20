<#
.SYNOPSIS
    Draws the button glyphs (config/ButtonIcons/glyphs/<style>/<input>.png).

.DESCRIPTION
    Compiles ButtonGlyphs.cs with the .NET Framework that ships with Windows (System.Drawing; no
    install) and writes one 128x128 PNG per physical input for the gamecube, playstation, xbox and
    switch styles, plus a keyboard key cap per DirectInput key name. The PNGs are committed: run
    this only to change the art, then review the result with -Preview.

.EXAMPLE
    .\tools-src\button-icons\make-button-glyphs.ps1 -Preview
#>
param(
    [string] $OutDir = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'config\ButtonIcons\glyphs'),
    [string] $Font = 'Arial Black',
    # Also writes build\button-glyphs-preview.png: every glyph on one sheet.
    [switch] $Preview
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -Path (Join-Path $PSScriptRoot 'ButtonGlyphs.cs') -ReferencedAssemblies System.Drawing

if (Test-Path -LiteralPath $OutDir) { Remove-Item -LiteralPath $OutDir -Recurse -Force }
$count = [ButtonGlyphs]::Generate($OutDir, $Font)
Write-Host "$count glyphs in $OutDir"

if ($Preview) {
    $files = Get-ChildItem $OutDir -Recurse -Filter *.png | Sort-Object { $_.Directory.Name -ne 'gamecube' }, { $_.Directory.Name }, Name
    $cell = 72; $columns = 16
    $rows = [Math]::Ceiling($files.Count / $columns)
    $bmp = New-Object Drawing.Bitmap ($columns * $cell), ($rows * $cell)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.Clear([Drawing.Color]::FromArgb(255, 40, 44, 52))
    $g.InterpolationMode = 'HighQualityBicubic'
    for ($i = 0; $i -lt $files.Count; $i++) {
        $img = [Drawing.Image]::FromFile($files[$i].FullName)
        $g.DrawImage($img, ($i % $columns) * $cell + 4, [Math]::Floor($i / $columns) * $cell + 4, 64, 64)
        $img.Dispose()
    }
    $buildDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'build'
    New-Item -ItemType Directory -Force $buildDir | Out-Null
    $path = Join-Path $buildDir 'button-glyphs-preview.png'
    $bmp.Save($path)
    Write-Host "preview: $path"
}
