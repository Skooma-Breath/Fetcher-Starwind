[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$umoRoot = Split-Path -Parent $projectRoot
$sourceRoot = if ($env:FETCHER_STARWIND_SOURCE_ROOT) { $env:FETCHER_STARWIND_SOURCE_ROOT } else { $umoRoot }
$buildData = Join-Path $projectRoot 'build\Data Files'
$assetData = Join-Path $projectRoot 'build\Starwind Vanilla Compat'
$converted = Join-Path $projectRoot 'converted'
$reports = Join-Path $projectRoot 'reports'
$tes3conv = Join-Path $sourceRoot 'starwind-modded\tes3conv.exe'
$python = 'C:\Users\REPTILE\AppData\Local\Programs\Python\Python312\python.exe'

function Convert-ForVerification([string]$pluginPath, [string]$jsonPath) {
    & $tes3conv $pluginPath $jsonPath
    if ($LASTEXITCODE -ne 0) { throw "tes3conv could not read generated plugin $pluginPath" }
    return Get-Content -Raw -Encoding UTF8 -LiteralPath $jsonPath | ConvertFrom-Json
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

$mappings = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $reports 'asset-namespace-map.json') | ConvertFrom-Json
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

$czerkaGuardText = "I'm an officer of the Czerka Corporation. Please behave yourself."
$czerkaGuardLines = @($core + $patch | Where-Object { $_.type -eq 'DialogueInfo' -and $_.text -eq $czerkaGuardText })
if ($czerkaGuardLines.Count -ne 1 -or $czerkaGuardLines[0].speaker_class -ne 'Guard' -or $czerkaGuardLines[0].speaker_faction -ne 'SW_Imperial Leg') {
    throw 'The generic Czerka guard line is not restricted to the private Starwind faction.'
}

$assollGreetingPrefix = 'Hey. Got a minute? I have money for you if you'
$assollGreetingText = "Hey. Got a minute? I have money for you if you$([char]0x2019)re interested in some work, Czerka needs your help."
$assollGreetings = @($patch | Where-Object {
    $_.type -eq 'DialogueInfo' -and $_.speaker_id -eq 'TatooineAssoll' -and
    $_.text.StartsWith($assollGreetingPrefix, [StringComparison]::Ordinal)
})
if ($assollGreetings.Count -ne 1 -or $assollGreetings[0].text -cne $assollGreetingText) {
    throw 'Tatooine Assoll greeting text was corrupted while processing UTF-8 dialogue JSON.'
}

$suranCells = @($patch | Where-Object { $_.type -eq 'Cell' -and $_.data.grid[0] -eq 6 -and $_.data.grid[1] -eq -6 })
if ($suranCells.Count -ne 1 -or @($suranCells[0].references).Count -ne 1) {
    throw 'Expected one minimal override for the original Suran exterior cell.'
}
$suranRock = @($suranCells[0].references | Where-Object {
    $_.mast_index -eq 1 -and $_.refr_index -eq 367187 -and $_.id -eq 'terrain_rock_ai_11' -and $_.deleted
})
if ($suranRock.Count -ne 1) { throw 'The rock obstructing the Suran COC spawn is not permanently deleted.' }

$officialBookSoundRoot = 'C:\Program Files (x86)\Steam\steamapps\common\Morrowind\Data Files\Sound\Fx\item'
$sourceDatapadSoundRoot = Join-Path $sourceRoot 'starwind-modded\TotalConversions\Starwindv3AStarWarsConversion\Starwind3.1\Data Files\Sound\Fx\item'
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

$officialLevelUp = 'C:\Program Files (x86)\Steam\steamapps\common\Morrowind\Data Files\Sound\Fx\inter\levelUP.wav'
$sourceStarwindLevelUp = Join-Path $sourceRoot 'starwind-modded\TotalConversions\Starwindv3AStarWarsConversion\Starwind3.1\Data Files\Sound\Fx\inter\levelUP.wav'
$overlaidLevelUp = Join-Path $assetData 'Sound\Fx\inter\levelUP.wav'
foreach ($path in @($officialLevelUp, $sourceStarwindLevelUp, $overlaidLevelUp)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Expected level-up sound is missing: $path" }
}
if ((Get-FileHash -Algorithm SHA256 $officialLevelUp).Hash -ne (Get-FileHash -Algorithm SHA256 $overlaidLevelUp).Hash) {
    throw 'The high-priority level-up cue is not the official Morrowind sound.'
}
if ((Get-FileHash -Algorithm SHA256 $sourceStarwindLevelUp).Hash -eq (Get-FileHash -Algorithm SHA256 $overlaidLevelUp).Hash) {
    throw 'The Starwind level-up cue is still overriding the vanilla sound.'
}

$datapadSoundRecords = @($core + $patch | Where-Object { $_.type -eq 'Sound' -and $_.id -in @('SW_Datapad Open', 'SW_Datapad Close') })
if ($datapadSoundRecords.Count -ne 2) { throw 'Expected private Starwind datapad open/close Sound records.' }

$trainingDatapads = @($patch | Where-Object { $_.type -eq 'Book' -and $_.id -eq 'SW_PlayerGen2' })
if ($trainingDatapads.Count -ne 1 -or -not [string]::IsNullOrEmpty([string]$trainingDatapads[0].script)) {
    throw 'The training datapad still runs its repeated inventory tutorial script.'
}

$rangedWeaponSoundNames = @(
    'bowAWAY.wav', 'bowOUT.wav', 'bowPULL.wav', 'bowSHOOT.wav',
    'cbowAWAY.wav', 'cbowOUT.wav', 'cbowPULL.wav', 'cbowSHOOT.wav', 'cbowshoot2.wav'
)
foreach ($soundName in $rangedWeaponSoundNames) {
    $officialSound = Join-Path $officialBookSoundRoot $soundName
    $overlaidSound = Join-Path $assetData "Sound\Fx\item\$soundName"
    foreach ($path in @($officialSound, $overlaidSound)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Expected ranged-weapon sound is missing: $path" }
    }
    if ((Get-FileHash -Algorithm SHA256 $officialSound).Hash -ne (Get-FileHash -Algorithm SHA256 $overlaidSound).Hash) {
        throw "The high-priority ranged-weapon sound is not the official Morrowind file: $soundName"
    }
}

$privateBlasterSoundSpecs = @(
    [PSCustomObject]@{ Id = 'SW_Compat_BlasterPull'; SourceName = 'bowPULL.wav'; PrivateName = 'blasterPULL.wav' },
    [PSCustomObject]@{ Id = 'SW_Compat_BlasterShoot'; SourceName = 'bowSHOOT.wav'; PrivateName = 'blasterSHOOT.wav' },
    [PSCustomObject]@{ Id = 'SW_Compat_RiflePull'; SourceName = 'cbowPULL.wav'; PrivateName = 'riflePULL.wav' },
    [PSCustomObject]@{ Id = 'SW_Compat_RifleShoot'; SourceName = 'cbowSHOOT.wav'; PrivateName = 'rifleSHOOT.wav' }
)
$privateBlasterSoundRecords = @($core + $patch | Where-Object {
    $_.type -eq 'Sound' -and $_.id -in @($privateBlasterSoundSpecs.Id)
})
if ($privateBlasterSoundRecords.Count -ne $privateBlasterSoundSpecs.Count) {
    throw 'The generated plugins do not contain exactly four private compatibility blaster Sound records.'
}
foreach ($sound in $privateBlasterSoundSpecs) {
    $record = @($privateBlasterSoundRecords | Where-Object { $_.id -eq $sound.Id })
    if ($record.Count -ne 1 -or $record[0].sound_path -ne "starwind_compat\$($sound.PrivateName)") {
        throw "Private compatibility blaster Sound record is invalid: $($sound.Id)"
    }
    $sourceSound = Join-Path $sourceRoot "starwind-modded\TotalConversions\Starwindv3AStarWarsConversion\Starwind3.1\Data Files\Sound\Fx\item\$($sound.SourceName)"
    $privateSound = Join-Path $assetData "Sound\starwind_compat\$($sound.PrivateName)"
    foreach ($path in @($sourceSound, $privateSound)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Expected private blaster sound is missing: $path" }
    }
    if ((Get-FileHash -Algorithm SHA256 $sourceSound).Hash -ne (Get-FileHash -Algorithm SHA256 $privateSound).Hash) {
        throw "Private compatibility blaster cue is not the original Starwind file: $($sound.SourceName)"
    }
}

$officialSplashRoot = 'C:\Program Files (x86)\Steam\steamapps\common\Morrowind\Data Files\Splash'
$sourceSplashRoot = Join-Path $sourceRoot 'starwind-modded\TotalConversions\Starwindv3AStarWarsConversion\Starwind3.1\Data Files\Splash'
$overlaidSplashRoot = Join-Path $assetData 'Splash'
$officialSplashes = @(Get-ChildItem -LiteralPath $officialSplashRoot -File -Filter '*.tga')
if ($officialSplashes.Count -ne 11) { throw "Expected 11 official splash screens, found $($officialSplashes.Count)." }
foreach ($splash in $officialSplashes) {
    $sourceSplash = Join-Path $sourceSplashRoot $splash.Name
    $overlaidSplash = Join-Path $overlaidSplashRoot $splash.Name
    foreach ($path in @($sourceSplash, $overlaidSplash)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Expected splash screen is missing: $path" }
    }
    if ((Get-FileHash -Algorithm SHA256 $splash.FullName).Hash -ne (Get-FileHash -Algorithm SHA256 $overlaidSplash).Hash) {
        throw "The high-priority splash is not the official Morrowind file: $($splash.Name)"
    }
    if ((Get-FileHash -Algorithm SHA256 $sourceSplash).Hash -eq (Get-FileHash -Algorithm SHA256 $overlaidSplash).Hash) {
        throw "The Starwind splash is still overriding the official file: $($splash.Name)"
    }
}

$requiredCreatureCompanions = @(
    'xancestorghost.kf', 'xashslave.kf', 'xbyagram.kf', 'xcavemudcrab.kf',
    'xcliffracer.kf', 'xdurzog.kf', 'xduskyalit.kf', 'xfabricant.kf',
    'xfabricant_hulking.kf', 'xfabricant_imperfect.kf', 'xfabricant_imperfect.nif',
    'xfrostgiant.kf', 'xgreatbonewalker.kf', 'xguar.kf', 'xice troll.kf',
    'xkwama forager.kf', 'xkwama warior.kf', 'xleastkagouti.kf',
    'xlordvivec.kf', 'xminescrib.kf', 'xnixhound.kf', 'xscamp_fetch.kf'
)
$privateCreatureRoot = Join-Path $assetData 'Meshes\starwind_compat\r'
foreach ($companionName in $requiredCreatureCompanions) {
    $privateCompanion = Join-Path $privateCreatureRoot $companionName
    if (-not (Test-Path -LiteralPath $privateCompanion -PathType Leaf)) {
        throw "Required creature animation companion is missing: $privateCompanion"
    }
}

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

$world = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $reports 'world-migration-map.json') | ConvertFrom-Json
$dialogue = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $reports 'dialogue-migration-map.json') | ConvertFrom-Json
$recordMap = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $reports 'record-id-migration-map.json') | ConvertFrom-Json
$scriptMap = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $reports 'script-global-migration-map.json') | ConvertFrom-Json
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
    --report (Join-Path $reports 'final-generated-conflicts.csv') `
    --allow-conflict 'Cell|exterior:6|-6' --fail-on-conflicts
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
