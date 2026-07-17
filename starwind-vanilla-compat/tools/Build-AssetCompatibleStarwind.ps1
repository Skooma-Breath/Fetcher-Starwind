[CmdletBinding()]
param(
    [int]$OverlayStartAt = 0,
    [int]$OverlayTake = 0,
    [switch]$SkipNamespace,
    [switch]$SkipOverlay,
    [switch]$SkipPluginBuild
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$umoRoot = Split-Path -Parent $projectRoot
$converted = Join-Path $projectRoot 'converted'
$buildDirectory = Join-Path $projectRoot 'build\Data Files'
$assetOutput = Join-Path $projectRoot 'build\Starwind Vanilla Compat'
$reportDir = Join-Path $projectRoot 'reports'
$tes3conv = Join-Path $umoRoot 'starwind-modded\tes3conv.exe'
$python = 'C:\Users\REPTILE\AppData\Local\Programs\Python\Python312\python.exe'
$bsatool = 'C:\Program Files\OpenMW 0.50.0\bsatool.exe'
$officialData = 'C:\Program Files (x86)\Steam\steamapps\common\Morrowind\Data Files'
$officialLooseData = 'C:\GOG Games\Morrowind\Data Files'
$starwindData = Join-Path $umoRoot 'starwind-modded\TotalConversions\Starwindv3AStarWarsConversion\Starwind3.1\Data Files'
$comparison = Join-Path $reportDir 'asset-bsa-collision-comparison.csv'
$mappingsPath = Join-Path $reportDir 'asset-namespace-map.json'

function Read-Plugin([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing converted plugin: $path" }
    return Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
}

function Write-PluginJson($plugin, [string]$path) {
    $json = $plugin | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))
}

function Build-Plugin([string]$jsonPath, [string]$pluginPath) {
    & $tes3conv $jsonPath $pluginPath
    if ($LASTEXITCODE -ne 0) { throw "tes3conv failed to build $pluginPath" }
}

function Normalize-PathValue([string]$value) {
    return $value.Replace('/', '\').TrimStart('\').ToLowerInvariant()
}

function Get-MappedValue($map, [string]$key) {
    $property = $map.PSObject.Properties[$key]
    if ($null -eq $property) { return $null }
    return [string]$property.Value
}

function Get-TextureMappedValue($map, [string]$value) {
    $key = Normalize-PathValue $value
    $mapped = Get-MappedValue $map $key
    if ($null -eq $mapped) {
        $mapped = Get-MappedValue $map "textures\$key"
        if ($null -ne $mapped -and -not $key.StartsWith('textures\')) {
            return $mapped.Substring('textures\'.Length)
        }
    }
    return $mapped
}

function Update-AssetLinks($plugin, $mappings, [string]$label) {
    $changed = [ordered]@{ Mesh = 0; Icon = 0; Texture = 0 }
    foreach ($record in @($plugin | Select-Object -Skip 1)) {
        foreach ($property in $record.PSObject.Properties) {
            if ($property.Value -is [string] -and -not [string]::IsNullOrWhiteSpace($property.Value)) {
                $mapped = $null
                if ($property.Name -eq 'mesh') {
                    $mapped = Get-MappedValue $mappings.mesh (Normalize-PathValue $property.Value)
                    if ($null -ne $mapped) { $changed.Mesh++ }
                } elseif ($property.Name -eq 'icon') {
                    $mapped = Get-MappedValue $mappings.icon (Normalize-PathValue $property.Value)
                    if ($null -ne $mapped) { $changed.Icon++ }
                } elseif ($property.Name -eq 'texture') {
                    $mapped = Get-TextureMappedValue $mappings.texture $property.Value
                    if ($null -ne $mapped) { $changed.Texture++ }
                }
                if ($null -ne $mapped) { $property.Value = $mapped }
            }
        }
    }
    Write-Output "$label assets remapped: meshes=$($changed.Mesh), icons=$($changed.Icon), textures=$($changed.Texture)"
    return $changed
}

foreach ($path in @($tes3conv, $python, $bsatool, $officialData, $starwindData, $comparison)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required input was not found: $path" }
}

$coreInput = Join-Path $converted 'StarwindRemasteredV1.15.global-compatible.json'
$patchInput = Join-Path $converted 'StarwindRemasteredPatch.global-compatible.json'
if (-not (Test-Path -LiteralPath $coreInput) -or -not (Test-Path -LiteralPath $patchInput)) {
    throw 'Run Build-GlobalCompatibleStarwind.ps1 before this asset build.'
}

if (-not $SkipNamespace) {
    & (Join-Path $PSScriptRoot 'Build-BookUiOverlay.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Build-BookUiOverlay.ps1 failed.' }
    $officialMeshData = if (Test-Path -LiteralPath (Join-Path $officialLooseData 'Meshes')) { $officialLooseData } else { $officialData }
    & $python (Join-Path $PSScriptRoot 'Namespace-StarwindAssets.py') '--source-data' $starwindData '--official-data' $officialMeshData '--comparison' $comparison '--output-data' $assetOutput '--mappings' $mappingsPath
    if ($LASTEXITCODE -ne 0) { throw 'Namespace-StarwindAssets.py failed.' }
}
if (-not (Test-Path -LiteralPath $mappingsPath)) { throw 'Missing asset mapping; run without -SkipNamespace first.' }

$overlayCount = 0
if (-not $SkipOverlay) {
    $changedAssets = @(Import-Csv -LiteralPath $comparison | Where-Object { $_.Content -eq 'Different' })
    if ($OverlayStartAt -lt 0 -or $OverlayStartAt -ge $changedAssets.Count) { throw "OverlayStartAt must be between 0 and $($changedAssets.Count - 1)." }
    if ($OverlayTake -gt 0) { $changedAssets = @($changedAssets | Select-Object -Skip $OverlayStartAt -First $OverlayTake) }
    elseif ($OverlayStartAt -gt 0) { $changedAssets = @($changedAssets | Select-Object -Skip $OverlayStartAt) }

    foreach ($asset in $changedAssets) {
        $archivePath = Join-Path $officialData $asset.OfficialArchive
        if (-not (Test-Path -LiteralPath $archivePath)) { throw "Missing official BSA: $archivePath" }
        & $bsatool extract -f $archivePath $asset.RelativePath $assetOutput | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not extract vanilla asset $($asset.RelativePath) from $($asset.OfficialArchive)" }
        $overlayCount++
    }
    Write-Output "Vanilla asset overlay extracted $overlayCount changed BSA assets."

    # Starwind also replaces a handful of loose official files. Restore the
    # vanilla level-up cue explicitly; it is not part of the BSA comparison
    # above and otherwise leaks into every non-Starwind world.
    $vanillaLevelUp = Join-Path $officialLooseData 'Sound\Fx\inter\levelUP.wav'
    if (-not (Test-Path -LiteralPath $vanillaLevelUp -PathType Leaf)) {
        $vanillaLevelUp = Join-Path $officialData 'Sound\Fx\inter\levelUP.wav'
    }
    if (-not (Test-Path -LiteralPath $vanillaLevelUp -PathType Leaf)) {
        throw 'The official Morrowind level-up sound was not found in either loose data directory.'
    }
    $overlaidLevelUp = Join-Path $assetOutput 'Sound\Fx\inter\levelUP.wav'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $overlaidLevelUp) | Out-Null
    Copy-Item -LiteralPath $vanillaLevelUp -Destination $overlaidLevelUp -Force
    Write-Output "Restored vanilla level-up sound: $overlaidLevelUp"
}

if ($SkipPluginBuild) {
    Write-Output 'Asset preparation complete; plugin build skipped by request.'
    exit 0
}

$mappings = Get-Content -Raw -LiteralPath $mappingsPath | ConvertFrom-Json
$core = Read-Plugin $coreInput
$coreChanges = Update-AssetLinks $core $mappings 'Core'
$coreOutput = Join-Path $converted 'StarwindRemasteredV1.15.asset-compatible.json'
Write-PluginJson $core $coreOutput
& $python (Join-Path $PSScriptRoot 'Migrate-StarwindWearableBodyparts.py') '--plugin' $coreOutput '--master' (Join-Path $converted 'Morrowind.json') '--mappings' $mappingsPath '--output' $coreOutput
if ($LASTEXITCODE -ne 0) { throw 'Migrate-StarwindWearableBodyparts.py failed for core.' }
$coreBuild = Join-Path $buildDirectory 'StarwindRemasteredV1.15.esm'
Build-Plugin $coreOutput $coreBuild
$coreBytes = (Get-Item -LiteralPath $coreBuild).Length

$core = $null
[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()

$patch = Read-Plugin $patchInput
$patchChanges = Update-AssetLinks $patch $mappings 'Patch'
$masterUpdated = 0
foreach ($master in $patch[0].masters) {
    if ($master[0] -eq 'StarwindRemasteredV1.15.esm') { $master[1] = $coreBytes; $masterUpdated++ }
}
if ($masterUpdated -ne 1) { throw "Expected one core master byte-count update; made $masterUpdated." }
$patchOutput = Join-Path $converted 'StarwindRemasteredPatch.asset-compatible.json'
Write-PluginJson $patch $patchOutput
& $python (Join-Path $PSScriptRoot 'Migrate-StarwindWearableBodyparts.py') '--plugin' $patchOutput '--master' (Join-Path $converted 'Morrowind.json') '--mappings' $mappingsPath '--output' $patchOutput
if ($LASTEXITCODE -ne 0) { throw 'Migrate-StarwindWearableBodyparts.py failed for patch.' }
$patchBuild = Join-Path $buildDirectory 'StarwindRemasteredPatch.esm'
Build-Plugin $patchOutput $patchBuild

[PSCustomObject]@{
    CorePlugin = $coreBuild
    PatchPlugin = $patchBuild
    AssetOverlayEntries = $overlayCount
    CoreMeshesRemapped = $coreChanges.Mesh
    PatchMeshesRemapped = $patchChanges.Mesh
    CoreIconsRemapped = $coreChanges.Icon
    PatchIconsRemapped = $patchChanges.Icon
    CoreTexturesRemapped = $coreChanges.Texture
    PatchTexturesRemapped = $patchChanges.Texture
    CoreBytes = $coreBytes
    PatchBytes = (Get-Item -LiteralPath $patchBuild).Length
} | Format-List
