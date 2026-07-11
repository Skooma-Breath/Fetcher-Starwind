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
$python = 'C:\Users\REPTILE\AppData\Local\Programs\Python\Python312\python.exe'

function Convert-ForVerification([string]$pluginPath, [string]$jsonPath) {
    & $tes3conv $pluginPath $jsonPath
    if ($LASTEXITCODE -ne 0) { throw "tes3conv could not read generated plugin $pluginPath" }
    return Get-Content -Raw -LiteralPath $jsonPath | ConvertFrom-Json
}

$corePath = Join-Path $buildData 'StarwindRemasteredV1.15.esm'
$patchPath = Join-Path $buildData 'StarwindRemasteredPatch.esm'
$tabletScript = Join-Path $assetData 'scripts\starwind-compat\tablet-reader.lua'
$blasterScript = Join-Path $assetData 'scripts\starwind-compat\blaster-animation-controller.lua'
foreach ($path in @($tes3conv, $python, $corePath, $patchPath, $tabletScript, $blasterScript, (Join-Path $reports 'world-migration-map.json'), (Join-Path $reports 'dialogue-migration-map.json'), (Join-Path $reports 'record-id-migration-map.json'), (Join-Path $reports 'script-global-migration-map.json'))) {
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
$vanillaDialogueRaceFilters = @($core + $patch | Where-Object { $_.type -eq 'DialogueInfo' -and $vanillaRaces -contains $_.speaker_race })
if ($vanillaDialogueRaceFilters.Count -ne 0) { throw 'Generated dialogue still applies Starwind voice lines to vanilla races.' }

$officialBookSoundRoot = 'C:\Program Files (x86)\Steam\steamapps\common\Morrowind\Data Files\Sound\Fx\item'
$sourceDatapadSoundRoot = Join-Path $umoRoot 'starwind-modded\TotalConversions\Starwindv3AStarWarsConversion\Starwind3.1\Data Files\Sound\Fx\item'
foreach ($soundName in @('bookopen.wav', 'bookclose.wav')) {
    $officialBookSound = Join-Path $officialBookSoundRoot $soundName
    $sourceDatapadSound = Join-Path $sourceDatapadSoundRoot $soundName
    $overlaidBookSound = Join-Path $assetData "Sound\Fx\item\$soundName"
    $privateDatapadSound = Join-Path $assetData "Sound\starwind_compat\$soundName"
    foreach ($path in @($officialBookSound, $sourceDatapadSound, $overlaidBookSound, $privateDatapadSound)) {
        if (-not (Test-Path -LiteralPath $path)) { throw "Expected book/datapad sound is missing: $path" }
    }
    if ((Get-FileHash -Algorithm SHA256 $officialBookSound).Hash -ne (Get-FileHash -Algorithm SHA256 $overlaidBookSound).Hash) {
        throw "The high-priority normal Book sound is not the official Morrowind file: $soundName"
    }
    if ((Get-FileHash -Algorithm SHA256 $sourceDatapadSound).Hash -ne (Get-FileHash -Algorithm SHA256 $privateDatapadSound).Hash) {
        throw "The private datapad sound is not the original Starwind file: $soundName"
    }
}
$officialMenuClick = Join-Path (Split-Path -Parent $officialBookSoundRoot) 'menu click.wav'
$sourceStarwindMenuClick = Join-Path (Split-Path -Parent $sourceDatapadSoundRoot) 'menu click.wav'
$overlaidMenuClick = Join-Path $assetData 'Sound\Fx\menu click.wav'
foreach ($path in @($officialMenuClick, $sourceStarwindMenuClick, $overlaidMenuClick)) {
    if (-not (Test-Path -LiteralPath $path)) { throw ('Expected GUI click sound is missing: ' + $path) }
}
if ((Get-FileHash -Algorithm SHA256 $officialMenuClick).Hash -ne (Get-FileHash -Algorithm SHA256 $overlaidMenuClick).Hash) {
    throw 'The high-priority Menu Click sound is not the official Morrowind file.'
}
if ((Get-FileHash -Algorithm SHA256 $sourceStarwindMenuClick).Hash -eq (Get-FileHash -Algorithm SHA256 $overlaidMenuClick).Hash) {
    throw 'The Starwind datapad beep is still overriding the shared Menu Click sound.'
}

$datapadSoundRecords = @($core + $patch | Where-Object { $_.type -eq 'Sound' -and $_.id -in @('SW_Datapad Open', 'SW_Datapad Close') })
if ($datapadSoundRecords.Count -ne 2) { throw 'Expected private Starwind datapad open/close Sound records.' }

$czerkaShirts = @($patch | Where-Object { $_.type -eq 'Clothing' -and $_.id -eq 'SW_CzerkaShirt1' })
if ($czerkaShirts.Count -ne 1) { throw 'Expected one Czerka Shirt override in the generated patch.' }
$czerkaMaleParts = @($czerkaShirts[0].biped_objects | Where-Object { $_.male_bodypart } | Select-Object -ExpandProperty male_bodypart)
if ($czerkaMaleParts.Count -ne 3 -or @($czerkaMaleParts | Where-Object { $_ -notlike 'SW_*' }).Count -ne 0) {
    throw 'Czerka Shirt no longer points to all three private orange bodyparts.'
}

$scriptRows = @(Import-Csv -LiteralPath (Join-Path $reports 'overridden-records.csv')) + @(Import-Csv -LiteralPath (Join-Path $reports 'patch-overridden-records.csv'))
$scriptIds = @($scriptRows | Where-Object { $_.RecordType -eq 'Script' } | Select-Object -ExpandProperty Id -Unique)
$scriptOverrides = @($core + $patch | Where-Object { $_.type -eq 'Script' -and $scriptIds -contains $_.id })
if ($scriptOverrides.Count -ne 0) { throw 'Generated plugins still override one or more official Script records.' }

$world = Get-Content -Raw -LiteralPath (Join-Path $reports 'world-migration-map.json') | ConvertFrom-Json
$dialogue = Get-Content -Raw -LiteralPath (Join-Path $reports 'dialogue-migration-map.json') | ConvertFrom-Json
$recordMap = Get-Content -Raw -LiteralPath (Join-Path $reports 'record-id-migration-map.json') | ConvertFrom-Json
$scriptMap = Get-Content -Raw -LiteralPath (Join-Path $reports 'script-global-migration-map.json') | ConvertFrom-Json
if ($world.offsetCells.x -ne 256 -or $world.offsetCells.y -ne 0) { throw 'The Starwind exterior world offset is not the expected isolated location.' }
if (@($world.interiorCellNames.PSObject.Properties).Count -ne 29) { throw 'Unexpected number of selectively migrated Starwind interior cells.' }
if (($world.core.scriptBytecodeTokens + $world.patch.scriptBytecodeTokens) -le 0) { throw 'World migration did not repair compiled script cell references.' }
if ($dialogue.infoRecordCount -ne 14640 -or @($dialogue.dialogueIds.PSObject.Properties).Count -ne 40) { throw 'Dialogue migration coverage is incomplete.' }
if (@($recordMap.recordIds.PSObject.Properties).Count -ne 191) { throw 'Remaining master-key record migration coverage is incomplete.' }
if (@($scriptMap.scriptIds.PSObject.Properties).Count -ne 19 -or @($scriptMap.globalIds.PSObject.Properties).Count -ne 2) { throw 'Script/global isolation coverage is incomplete.' }

$audit = Join-Path $PSScriptRoot 'Audit-StarwindConflicts.py'
& $python $audit `
    --master (Join-Path $converted 'Morrowind.json') `
    --master (Join-Path $converted 'Tribunal.json') `
    --master (Join-Path $converted 'Bloodmoon.json') `
    --plugin (Join-Path $converted 'verify-final-core.json') `
    --plugin (Join-Path $converted 'verify-final-patch.json') `
    --report (Join-Path $reports 'final-generated-conflicts.csv') --fail-on-conflicts
if ($LASTEXITCODE -ne 0) { throw 'The generated ESMs still contain a master-key conflict.' }

[PSCustomObject]@{
    CorePlugin = $corePath
    PatchPlugin = $patchPath
    CoreBytes = $coreBytes
    VanillaBookUiTextures = $vanillaBookUiCount
    VanillaAssetOverlayEntries = $changedAssets.Count
    NamespacedMeshes = $mappings.summary.meshesNamespaced
    NamespacedTextures = $mappings.summary.changedTexturesCopied
    NamespacedIcons = $mappings.summary.changedIconsCopied
    IsolatedInteriors = @($world.interiorCellNames.PSObject.Properties).Count
    IsolatedDialogueInfos = $dialogue.infoRecordCount
    IsolatedRecordIds = @($recordMap.recordIds.PSObject.Properties).Count
    Status = 'Generated ESMs re-read successfully; all master-key conflict checks passed.'
} | Format-List
