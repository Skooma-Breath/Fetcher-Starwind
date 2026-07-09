[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$umoRoot = Split-Path -Parent $projectRoot
$python = 'C:\Users\REPTILE\AppData\Local\Programs\Python\Python312\python.exe'
$sourceData = Join-Path $umoRoot 'starwind-modded\TotalConversions\Starwindv3AStarWarsConversion\Starwind3.1\Data Files'
$outputData = Join-Path $projectRoot 'build\Starwind Vanilla Compat'
$assets = Join-Path $projectRoot 'assets'

foreach ($path in @($python, $sourceData, $assets)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required input was not found: $path" }
}
& $python (Join-Path $PSScriptRoot 'Build-BlasterAnimationSources.py') '--source-data' $sourceData '--output-data' $outputData '--assets' $assets
if ($LASTEXITCODE -ne 0) { throw 'Build-BlasterAnimationSources.py failed.' }
