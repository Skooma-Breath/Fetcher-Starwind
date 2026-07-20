[CmdletBinding()]
param(
    [string] $OfficialDataRoot = "",
    [string] $OfficialLooseDataRoot = "",
    [string] $BsaToolPath = "",
    [string] $PythonPath = "",
    [string] $OutputPath = ""
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($OfficialDataRoot)) {
    $OfficialDataRoot = if ($env:FETCHER_MORROWIND_DATA_ROOT) {
        $env:FETCHER_MORROWIND_DATA_ROOT
    }
    else {
        'C:\Program Files (x86)\Steam\steamapps\common\Morrowind\Data Files'
    }
}
if ([string]::IsNullOrWhiteSpace($OfficialLooseDataRoot)) {
    $OfficialLooseDataRoot = if ($env:FETCHER_MORROWIND_LOOSE_DATA_ROOT) {
        $env:FETCHER_MORROWIND_LOOSE_DATA_ROOT
    }
    else {
        'C:\GOG Games\Morrowind\Data Files'
    }
}
if ([string]::IsNullOrWhiteSpace($BsaToolPath)) {
    $BsaToolPath = if ($env:FETCHER_BSATOOL_PATH) {
        $env:FETCHER_BSATOOL_PATH
    }
    else {
        'C:\Program Files\OpenMW 0.50.0\bsatool.exe'
    }
}
if ([string]::IsNullOrWhiteSpace($PythonPath)) {
    $PythonPath = if ($env:FETCHER_PYTHON_PATH) {
        $env:FETCHER_PYTHON_PATH
    }
    else {
        'C:\Users\REPTILE\AppData\Local\Programs\Python\Python312\python.exe'
    }
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $projectRoot 'reports\morrowind-local-assets.json'
}

foreach ($required in @(
    $OfficialDataRoot,
    $BsaToolPath,
    $PythonPath,
    (Join-Path $projectRoot 'build\Starwind Vanilla Compat'),
    (Join-Path $projectRoot 'reports\asset-bsa-collision-comparison.csv'),
    (Join-Path $projectRoot 'reports\asset-namespace-map.json'),
    (Join-Path $PSScriptRoot 'Build-MorrowindLocalAssetManifest.py')
)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Required input was not found: $required"
    }
}

$arguments = @(
    (Join-Path $PSScriptRoot 'Build-MorrowindLocalAssetManifest.py'),
    '--overlay', (Join-Path $projectRoot 'build\Starwind Vanilla Compat'),
    '--comparison', (Join-Path $projectRoot 'reports\asset-bsa-collision-comparison.csv'),
    '--namespace-map', (Join-Path $projectRoot 'reports\asset-namespace-map.json'),
    '--official-data', $OfficialDataRoot,
    '--bsatool', $BsaToolPath,
    '--output', $OutputPath
)
if (-not [string]::IsNullOrWhiteSpace($OfficialLooseDataRoot) -and
    (Test-Path -LiteralPath $OfficialLooseDataRoot -PathType Container)) {
    $arguments += @('--official-loose-data', $OfficialLooseDataRoot)
}

& $PythonPath @arguments
if ($LASTEXITCODE -ne 0) {
    throw 'Build-MorrowindLocalAssetManifest.py failed.'
}

$manifest = Get-Content -LiteralPath $OutputPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([int]$manifest.schemaVersion -ne 1 -or
    [string]$manifest.manifestId -ne 'fetcher-starwind-local-morrowind-assets') {
    throw "Generated local Morrowind asset manifest is unsupported: $OutputPath"
}
Write-Host "Created local Morrowind reconstruction manifest with $(@($manifest.files).Count) file recipe(s):"
Write-Host "  $OutputPath"
