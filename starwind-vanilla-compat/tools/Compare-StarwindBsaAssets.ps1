[CmdletBinding()]
param(
    [int]$StartAt = 0,
    [int]$Take = 0
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$umoRoot = Split-Path -Parent $projectRoot
$starwindData = Join-Path $umoRoot 'starwind-modded\TotalConversions\Starwindv3AStarWarsConversion\Starwind3.1\Data Files'
$officialData = 'C:\Program Files (x86)\Steam\steamapps\common\Morrowind\Data Files'
$reportDir = Join-Path $projectRoot 'reports'
$bsatool = 'C:\Program Files\OpenMW 0.50.0\bsatool.exe'
$collisionReport = Join-Path $reportDir 'asset-path-collisions.csv'
$tempRoot = Join-Path $reportDir '_bsa-compare-temp'

foreach ($path in @($starwindData, $officialData, $bsatool, $collisionReport)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required input was not found: $path" }
}

function Remove-VerifiedTemporaryDirectory([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return }
    $expected = [System.IO.Path]::GetFullPath((Join-Path $reportDir '_bsa-compare-temp')).TrimEnd('\')
    $actual = [System.IO.Path]::GetFullPath($path).TrimEnd('\')
    if ($actual -ne $expected) { throw "Refusing to delete unexpected temporary path: $actual" }
    Remove-Item -LiteralPath $actual -Recurse -Force
}

Remove-VerifiedTemporaryDirectory $tempRoot
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
    $candidates = @(Import-Csv -LiteralPath $collisionReport | Where-Object {
        $_.Content -eq 'BsaOnly' -and $_.Extension -in @('.dds', '.nif', '.kf')
    })
    if ($candidates.Count -eq 0) { throw 'No BSA-only mesh, animation, or texture collisions were found. Run Find-StarwindAssetCollisions.ps1 first.' }
    $totalCandidates = $candidates.Count
    if ($StartAt -lt 0 -or $StartAt -ge $totalCandidates) { throw "StartAt must be between 0 and $($totalCandidates - 1)." }
    if ($Take -gt 0) { $candidates = @($candidates | Select-Object -Skip $StartAt -First $Take) }
    elseif ($StartAt -gt 0) { $candidates = @($candidates | Select-Object -Skip $StartAt) }

    $archivePriority = @('Bloodmoon.bsa', 'Tribunal.bsa', 'Morrowind.bsa')
    $comparison = @()
    $index = 0
    foreach ($candidate in $candidates) {
        $index++
        $archives = @($candidate.OfficialSource -split '; ')
        $archive = $archivePriority | Where-Object { $archives -contains $_ } | Select-Object -First 1
        if (-not $archive) { throw "No recognized BSA source for $($candidate.RelativePath)" }
        $bsaPath = Join-Path $officialData $archive
        & $bsatool extract -f $bsaPath $candidate.RelativePath $tempRoot | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not extract $($candidate.RelativePath) from $archive" }

        $extractedPath = Join-Path $tempRoot $candidate.RelativePath
        if (-not (Test-Path -LiteralPath $extractedPath -PathType Leaf)) { throw "BSA extraction did not create $extractedPath" }
        $sourcePath = Join-Path $starwindData $candidate.RelativePath
        $content = if ($candidate.SourceBytes -ne (Get-Item -LiteralPath $extractedPath).Length) {
            'Different'
        } elseif ((Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $extractedPath -Algorithm SHA256).Hash) {
            'Identical'
        } else {
            'Different'
        }
        $comparison += [PSCustomObject]@{
            RelativePath = $candidate.RelativePath
            AssetRoot = $candidate.AssetRoot
            Extension = $candidate.Extension
            SourceBytes = [int64]$candidate.SourceBytes
            OfficialArchive = $archive
            OfficialBytes = (Get-Item -LiteralPath $extractedPath).Length
            Content = $content
        }
        Remove-Item -LiteralPath $extractedPath -Force
        if (($index % 50) -eq 0) { Write-Output "Compared $index of $($candidates.Count) BSA assets in this chunk." }
    }

    $suffix = if ($StartAt -eq 0 -and $Take -eq 0) { '' } else { ".part-$StartAt" }
    $comparison | Export-Csv -LiteralPath (Join-Path $reportDir "asset-bsa-collision-comparison$suffix.csv") -NoTypeInformation -Encoding utf8
    $summary = $comparison | Group-Object AssetRoot, Extension, Content | ForEach-Object {
        $parts = $_.Name -split ', '
        [PSCustomObject]@{ AssetRoot = $parts[0]; Extension = $parts[1]; Content = $parts[2]; Count = $_.Count }
    } | Sort-Object AssetRoot, Extension, Content
    $summary | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $reportDir 'asset-bsa-collision-summary.json') -Encoding utf8
    $summary | Format-Table -AutoSize
    Write-Output "Compared $($comparison.Count) BSA assets in this chunk (source range starts at $StartAt of $totalCandidates)."
} finally {
    Remove-VerifiedTemporaryDirectory $tempRoot
}
