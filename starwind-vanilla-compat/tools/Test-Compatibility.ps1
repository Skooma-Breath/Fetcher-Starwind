[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$umoRoot = Split-Path -Parent $projectRoot
$buildData = Join-Path $projectRoot 'build\Data Files'
$assetData = Join-Path $projectRoot 'build\Starwind Vanilla Compat'
$converted = Join-Path $projectRoot 'converted'
$reports = Join-Path $projectRoot 'reports'
$tes3conv = Join-Path $umoRoot 'starwind-modded\tes3conv.exe'

function Convert-ForVerification([string]$pluginPath, [string]$jsonPath) {
    & $tes3conv $pluginPath $jsonPath
    if ($LASTEXITCODE -ne 0) { throw "tes3conv could not read generated plugin $pluginPath" }
    return Get-Content -Raw -LiteralPath $jsonPath | ConvertFrom-Json
}

$corePath = Join-Path $buildData 'StarwindRemasteredV1.15.esm'
$patchPath = Join-Path $buildData 'StarwindRemasteredPatch.esm'
$tabletScript = Join-Path $assetData 'scripts\starwind-compat\tablet-reader.lua'
$blasterScript = Join-Path $assetData 'scripts\starwind-compat\blaster-animation-controller.lua'
foreach ($path in @($tes3conv, $corePath, $patchPath, $tabletScript, $blasterScript)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Expected generated output is missing: $path" }
}

$core = Convert-ForVerification $corePath (Join-Path $converted 'verify-final-core.json')
$patch = Convert-ForVerification $patchPath (Join-Path $converted 'verify-final-patch.json')
$coreBytes = (Get-Item -LiteralPath $corePath).Length
$master = @($patch[0].masters | Where-Object { $_[0] -eq 'StarwindRemasteredV1.15.esm' })
if ($master.Count -ne 1 -or $master[0][1] -ne $coreBytes) { throw 'Patch core-master byte count does not match the generated core ESM.' }

$vanillaBookUiCount = @(Get-ChildItem -LiteralPath (Join-Path $assetData 'Textures') -Filter 'tx_menubook*.dds' -File).Count
if ($vanillaBookUiCount -ne 35) { throw "Expected 35 vanilla Book UI textures, found $vanillaBookUiCount." }

$assetReport = Import-Csv -LiteralPath (Join-Path $reports 'asset-bsa-collision-comparison.csv')
$changedAssets = @($assetReport | Where-Object { $_.Content -eq 'Different' })
$missingVanillaAssets = @($changedAssets | Where-Object { -not (Test-Path -LiteralPath (Join-Path $assetData $_.RelativePath)) })
if ($missingVanillaAssets.Count -ne 0) { throw "Vanilla asset overlay is missing $($missingVanillaAssets.Count) changed asset paths." }

$mappings = Get-Content -Raw -LiteralPath (Join-Path $reports 'asset-namespace-map.json') | ConvertFrom-Json
foreach ($category in @('mesh', 'icon', 'texture')) {
    foreach ($property in $mappings.$category.PSObject.Properties) {
        $relative = $property.Value
        $expected = if ($category -eq 'mesh') { Join-Path $assetData "Meshes\$relative" } elseif ($category -eq 'icon') { Join-Path $assetData "Icons\$relative" } else { Join-Path $assetData $relative }
        if (-not (Test-Path -LiteralPath $expected)) { throw "Missing namespaced $category asset: $expected" }
    }
}

$vanillaRaces = @('Argonian','Breton','Dark Elf','High Elf','Imperial','Khajiit','Nord','Orc','Redguard','Wood Elf')
$vanillaRaceOverrides = @($core + $patch | Where-Object { $_.type -eq 'Race' -and $vanillaRaces -contains $_.id })
if ($vanillaRaceOverrides.Count -ne 0) { throw 'Generated plugins still override one or more vanilla playable races.' }

$scriptRows = @(Import-Csv -LiteralPath (Join-Path $reports 'overridden-records.csv')) + @(Import-Csv -LiteralPath (Join-Path $reports 'patch-overridden-records.csv'))
$scriptIds = @($scriptRows | Where-Object { $_.RecordType -eq 'Script' } | Select-Object -ExpandProperty Id -Unique)
$scriptOverrides = @($core + $patch | Where-Object { $_.type -eq 'Script' -and $scriptIds -contains $_.id })
if ($scriptOverrides.Count -ne 0) { throw 'Generated plugins still override one or more official Script records.' }

[PSCustomObject]@{
    CorePlugin = $corePath
    PatchPlugin = $patchPath
    CoreBytes = $coreBytes
    VanillaBookUiTextures = $vanillaBookUiCount
    VanillaAssetOverlayEntries = $changedAssets.Count
    NamespacedMeshes = $mappings.summary.meshesNamespaced
    NamespacedTextures = $mappings.summary.changedTexturesCopied
    NamespacedIcons = $mappings.summary.changedIconsCopied
    Status = 'Generated ESMs re-read successfully and compatibility invariants passed.'
} | Format-List
