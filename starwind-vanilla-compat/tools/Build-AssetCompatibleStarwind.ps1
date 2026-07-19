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
$sourceRoot = if ($env:FETCHER_STARWIND_SOURCE_ROOT) { $env:FETCHER_STARWIND_SOURCE_ROOT } else { $umoRoot }
$converted = Join-Path $projectRoot 'converted'
$buildDirectory = Join-Path $projectRoot 'build\Data Files'
$assetOutput = Join-Path $projectRoot 'build\Starwind Vanilla Compat'
$reportDir = Join-Path $projectRoot 'reports'
$tes3conv = Join-Path $sourceRoot 'starwind-modded\tes3conv.exe'
$python = 'C:\Users\REPTILE\AppData\Local\Programs\Python\Python312\python.exe'
$bsatool = 'C:\Program Files\OpenMW 0.50.0\bsatool.exe'
$officialData = 'C:\Program Files (x86)\Steam\steamapps\common\Morrowind\Data Files'
$officialLooseData = 'C:\GOG Games\Morrowind\Data Files'
$starwindData = Join-Path $sourceRoot 'starwind-modded\TotalConversions\Starwindv3AStarWarsConversion\Starwind3.1\Data Files'
$comparison = Join-Path $reportDir 'asset-bsa-collision-comparison.csv'
$mappingsPath = Join-Path $reportDir 'asset-namespace-map.json'

$privateBlasterSounds = @(
    [PSCustomObject]@{
        Id = 'SW_Compat_BlasterPull'
        SourceName = 'bowPULL.wav'
        PrivateName = 'blasterPULL.wav'
    },
    [PSCustomObject]@{
        Id = 'SW_Compat_BlasterShoot'
        SourceName = 'bowSHOOT.wav'
        PrivateName = 'blasterSHOOT.wav'
    },
    [PSCustomObject]@{
        Id = 'SW_Compat_RiflePull'
        SourceName = 'cbowPULL.wav'
        PrivateName = 'riflePULL.wav'
    },
    [PSCustomObject]@{
        Id = 'SW_Compat_RifleShoot'
        SourceName = 'cbowSHOOT.wav'
        PrivateName = 'rifleSHOOT.wav'
    }
)

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

    # Several vanilla creature models use companion animation filenames that
    # do not exactly match x<mesh-stem>. Keep these beside their namespaced
    # models so the relocated creatures retain their animation sources.
    $requiredCreatureCompanions = @(
        'xancestorghost.kf', 'xashslave.kf', 'xbyagram.kf', 'xcavemudcrab.kf',
        'xcliffracer.kf', 'xdurzog.kf', 'xduskyalit.kf', 'xfabricant.kf',
        'xfabricant_hulking.kf', 'xfabricant_imperfect.kf', 'xfabricant_imperfect.nif',
        'xfrostgiant.kf', 'xgreatbonewalker.kf', 'xguar.kf', 'xice troll.kf',
        'xkwama forager.kf', 'xkwama warior.kf', 'xleastkagouti.kf',
        'xlordvivec.kf', 'xminescrib.kf', 'xnixhound.kf', 'xscamp_fetch.kf'
    )
    $officialCreatureRoot = Join-Path $officialMeshData 'Meshes\r'
    $privateCreatureRoot = Join-Path $assetOutput 'Meshes\starwind_compat\r'
    New-Item -ItemType Directory -Force -Path $privateCreatureRoot | Out-Null
    foreach ($companionName in $requiredCreatureCompanions) {
        $privateCompanion = Join-Path $privateCreatureRoot $companionName
        if (Test-Path -LiteralPath $privateCompanion -PathType Leaf) {
            continue
        }
        $sourceCompanion = Join-Path $officialCreatureRoot $companionName
        if (-not (Test-Path -LiteralPath $sourceCompanion -PathType Leaf)) {
            throw "Required official creature animation companion is missing: $sourceCompanion"
        }
        Copy-Item -LiteralPath $sourceCompanion -Destination $privateCompanion -Force
    }
    Write-Output "Verified $($requiredCreatureCompanions.Count) required creature animation companions."
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

    # Starwind replaces the shared bow and crossbow sound files with blaster
    # effects. Restore every vanilla ranged-weapon cue at the high-priority
    # compatibility layer so normal bows keep their draw and release audio.
    $vanillaRangedWeaponSounds = @(
        'bowAWAY.wav',
        'bowOUT.wav',
        'bowPULL.wav',
        'bowSHOOT.wav',
        'cbowAWAY.wav',
        'cbowOUT.wav',
        'cbowPULL.wav',
        'cbowSHOOT.wav',
        'cbowshoot2.wav'
    )
    foreach ($soundName in $vanillaRangedWeaponSounds) {
        $vanillaSound = Join-Path $officialLooseData "Sound\Fx\item\$soundName"
        if (-not (Test-Path -LiteralPath $vanillaSound -PathType Leaf)) {
            $vanillaSound = Join-Path $officialData "Sound\Fx\item\$soundName"
        }
        if (-not (Test-Path -LiteralPath $vanillaSound -PathType Leaf)) {
            throw "The official Morrowind ranged-weapon sound was not found: $soundName"
        }
        $overlaidSound = Join-Path $assetOutput "Sound\Fx\item\$soundName"
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $overlaidSound) | Out-Null
        Copy-Item -LiteralPath $vanillaSound -Destination $overlaidSound -Force
    }
    Write-Output "Restored $($vanillaRangedWeaponSounds.Count) vanilla bow/crossbow sounds."

    # Starwind replaces the same eleven loose splash filenames used by the
    # official game. Restore all of them at the highest-priority compatibility
    # layer so startup and loading screens remain vanilla outside Starwind.
    $officialSplashRoot = Join-Path $officialLooseData 'Splash'
    if (-not (Test-Path -LiteralPath $officialSplashRoot -PathType Container)) {
        $officialSplashRoot = Join-Path $officialData 'Splash'
    }
    $officialSplashes = @(Get-ChildItem -LiteralPath $officialSplashRoot -File -Filter '*.tga')
    if ($officialSplashes.Count -ne 11) {
        throw "Expected 11 official Morrowind splash screens, found $($officialSplashes.Count) in $officialSplashRoot."
    }
    $overlaidSplashRoot = Join-Path $assetOutput 'Splash'
    New-Item -ItemType Directory -Force -Path $overlaidSplashRoot | Out-Null
    foreach ($splash in $officialSplashes) {
        Copy-Item -LiteralPath $splash.FullName -Destination (Join-Path $overlaidSplashRoot $splash.Name) -Force
    }
    Write-Output "Restored $($officialSplashes.Count) vanilla startup/loading splash screens."
}

# Keep the original Starwind blaster cues under private paths. The private
# swblaster animation group references Sound records added to the patch below,
# avoiding any collision with Morrowind's shared BowPull/BowShoot records.
$privateBlasterSoundRoot = Join-Path $assetOutput 'Sound\starwind_compat'
New-Item -ItemType Directory -Force -Path $privateBlasterSoundRoot | Out-Null
foreach ($sound in $privateBlasterSounds) {
    $sourceSound = Join-Path $starwindData "Sound\Fx\item\$($sound.SourceName)"
    if (-not (Test-Path -LiteralPath $sourceSound -PathType Leaf)) {
        throw "Required original Starwind blaster sound is missing: $sourceSound"
    }
    Copy-Item -LiteralPath $sourceSound -Destination (Join-Path $privateBlasterSoundRoot $sound.PrivateName) -Force
}
Write-Output "Copied $($privateBlasterSounds.Count) original Starwind blaster cues to private paths."

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
$existingPrivateSoundRecords = @($patch | Where-Object {
    $_.type -eq 'Sound' -and $_.id -in @($privateBlasterSounds.Id)
})
if ($existingPrivateSoundRecords.Count -ne 0) {
    throw 'The pre-asset patch unexpectedly already contains a private compatibility blaster Sound record.'
}
foreach ($sound in $privateBlasterSounds) {
    $patch += [PSCustomObject][ordered]@{
        type = 'Sound'
        flags = ''
        id = $sound.Id
        sound_path = "starwind_compat\$($sound.PrivateName)"
        data = [ordered]@{
            volume = 255
            range = @(0, 0)
        }
    }
}
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
