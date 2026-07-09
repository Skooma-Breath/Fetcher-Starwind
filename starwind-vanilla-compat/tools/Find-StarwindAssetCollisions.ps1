[CmdletBinding()]
param(
    [switch]$SkipHash
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$umoRoot = Split-Path -Parent $projectRoot
$starwindData = Join-Path $umoRoot 'starwind-modded\TotalConversions\Starwindv3AStarWarsConversion\Starwind3.1\Data Files'
$officialData = 'C:\Program Files (x86)\Steam\steamapps\common\Morrowind\Data Files'
$reportDir = Join-Path $projectRoot 'reports'

if (-not (Test-Path -LiteralPath $starwindData)) { throw "Starwind data files were not found at $starwindData" }
if (-not (Test-Path -LiteralPath $officialData)) { throw "Official data files were not found at $officialData" }
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null

$collisions = foreach ($source in Get-ChildItem -LiteralPath $starwindData -Recurse -File) {
    $relativePath = $source.FullName.Substring($starwindData.Length).TrimStart('\')
    $officialPath = Join-Path $officialData $relativePath
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
            Content = $contentState
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
