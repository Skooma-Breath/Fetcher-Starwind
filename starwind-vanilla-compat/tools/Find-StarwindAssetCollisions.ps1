[CmdletBinding()]
param(
    [switch]$SkipHash
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$umoRoot = Split-Path -Parent $projectRoot
$sourceRoot = if ($env:FETCHER_STARWIND_SOURCE_ROOT) { $env:FETCHER_STARWIND_SOURCE_ROOT } else { $umoRoot }
$starwindData = Join-Path $sourceRoot 'starwind-modded\TotalConversions\Starwindv3AStarWarsConversion\Starwind3.1\Data Files'
$officialData = 'C:\Program Files (x86)\Steam\steamapps\common\Morrowind\Data Files'
$reportDir = Join-Path $projectRoot 'reports'
$bsatool = 'C:\Program Files\OpenMW 0.50.0\bsatool.exe'

if (-not (Test-Path -LiteralPath $starwindData)) { throw "Starwind data files were not found at $starwindData" }
if (-not (Test-Path -LiteralPath $officialData)) { throw "Official data files were not found at $officialData" }
if (-not (Test-Path -LiteralPath $bsatool)) { throw "bsatool was not found at $bsatool" }
$starwindData = (Resolve-Path -LiteralPath $starwindData).Path.TrimEnd([IO.Path]::DirectorySeparatorChar)
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null

function Get-BsaAssetIndex([string]$bsaPath) {
    $index = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($line in & $bsatool list -l $bsaPath) {
        if ($line -match '^(.+?)\s+(\d+)\s+@\s+0x[0-9a-fA-F]+$') {
            $path = ($Matches[1].Trim() -replace '\\', '/').ToLowerInvariant()
            $index[$path] = [int64]$Matches[2]
        }
    }
    return $index
}

$bsaIndexes = @{}
foreach ($bsaName in @('Morrowind.bsa', 'Tribunal.bsa', 'Bloodmoon.bsa')) {
    $bsaPath = Join-Path $officialData $bsaName
    if (Test-Path -LiteralPath $bsaPath) {
        $bsaIndexes[$bsaName] = Get-BsaAssetIndex $bsaPath
    }
}

$collisions = foreach ($source in Get-ChildItem -LiteralPath $starwindData -Recurse -File) {
    $relativePath = $source.FullName.Substring($starwindData.Length).TrimStart('\')
    $officialPath = Join-Path $officialData $relativePath
    $bsaPath = ($relativePath -replace '\\', '/').ToLowerInvariant()
    $bsaMatches = @()
    foreach ($entry in $bsaIndexes.GetEnumerator()) {
        if ($entry.Value.ContainsKey($bsaPath)) {
            $bsaMatches += [PSCustomObject]@{ Archive = $entry.Key; Bytes = $entry.Value[$bsaPath] }
        }
    }
    if (Test-Path -LiteralPath $officialPath -PathType Leaf) {
        $official = Get-Item -LiteralPath $officialPath
        $contentState = if ($SkipHash) {
            'NotHashed'
        } elseif ($source.Length -ne $official.Length) {
            'Different'
        } elseif ((Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $official.FullName -Algorithm SHA256).Hash) {
            'Identical'
        } else {
            'Different'
        }

        [PSCustomObject]@{
            RelativePath = $relativePath
            AssetRoot = ($relativePath -split '\\')[0]
            Extension = $source.Extension.ToLowerInvariant()
            SourceBytes = $source.Length
            OfficialBytes = $official.Length
            OfficialSource = if ($bsaMatches.Count -eq 0) { 'Loose Data Files' } else { "Loose Data Files; " + (($bsaMatches | ForEach-Object Archive) -join '; ') }
            Content = $contentState
        }
    } elseif ($bsaMatches.Count -gt 0) {
        [PSCustomObject]@{
            RelativePath = $relativePath
            AssetRoot = ($relativePath -split '\\')[0]
            Extension = $source.Extension.ToLowerInvariant()
            SourceBytes = $source.Length
            OfficialBytes = (($bsaMatches | Select-Object -First 1).Bytes)
            OfficialSource = (($bsaMatches | ForEach-Object Archive) -join '; ')
            Content = 'BsaOnly'
        }
    }
}

$collisions = @($collisions | Sort-Object RelativePath)
$collisions | Export-Csv -LiteralPath (Join-Path $reportDir 'asset-path-collisions.csv') -NoTypeInformation -Encoding utf8
$summary = $collisions | Group-Object AssetRoot, Extension, Content | ForEach-Object {
    $parts = $_.Name -split ', '
    [PSCustomObject]@{ AssetRoot = $parts[0]; Extension = $parts[1]; Content = $parts[2]; Count = $_.Count }
} | Sort-Object AssetRoot, Extension, Content
$summary | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $reportDir 'asset-collision-summary.json') -Encoding utf8

$summary | Format-Table -AutoSize
Write-Output "Total colliding asset paths: $($collisions.Count)"
Write-Output "BSA archives indexed: $($bsaIndexes.Keys -join ', ')"
