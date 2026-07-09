[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$umoRoot = Split-Path -Parent $projectRoot
$converted = Join-Path $projectRoot 'converted'
$buildDirectory = Join-Path $projectRoot 'build\Data Files'
$tes3conv = Join-Path $umoRoot 'starwind-modded\tes3conv.exe'

# Body-part IDs encode their race name. These are the already-migrated Starwind
# races whose former vanilla body parts must become independent selections.
$bodypartRaceMap = [ordered]@{
    'Argonian' = 'SW_Gungan'; 'Dark Elf' = 'SW_Duros'; 'High Elf' = 'SW_Twilek'
    'Khajiit' = 'SW_Cathar'; 'Nord' = 'SW_Mandalorian'; 'Orc' = 'SW_Rodian'; 'Wood Elf' = 'SW_Droid'
}

function Read-Plugin([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing converted plugin: $path" }
    return Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
}

function Get-NewBodypartId([string]$oldId) {
    foreach ($oldRace in $bodypartRaceMap.Keys) {
        $pattern = "(?i)^b_n_$([regex]::Escape($oldRace))(?<tail>_.+)$"
        if ($oldId -match $pattern) {
            return "b_n_$($bodypartRaceMap[$oldRace].ToLowerInvariant())$($Matches['tail'])"
        }
    }
    return "SW_$oldId"
}

function Remap-Field($records, [string]$recordType, [string]$field, $idMap) {
    $changed = 0
    foreach ($record in $records | Where-Object { $_.type -eq $recordType }) {
        if ($record.PSObject.Properties.Name -contains $field) {
            $value = $record.$field
            if ($idMap.Contains($value)) {
                $record.$field = $idMap[$value]
                $changed++
            }
        }
    }
    return $changed
}

function Remap-BipedObjects($records, $idMap) {
    $changed = 0
    foreach ($record in $records | Where-Object { $_.type -in @('Armor', 'Clothing') }) {
        foreach ($part in $record.biped_objects) {
            foreach ($field in @('male_bodypart', 'female_bodypart')) {
                if ($idMap.Contains($part.$field)) {
                    $part.$field = $idMap[$part.$field]
                    $changed++
                }
            }
        }
    }
    return $changed
}

function Assert-Count([string]$label, [int]$actual, [int]$expected) {
    if ($actual -ne $expected) { throw "$label expected $expected changes; made $actual." }
}

function Write-PluginJson($plugin, [string]$path) {
    $json = $plugin | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))
}

function Build-Plugin([string]$jsonPath, [string]$pluginPath) {
    & $tes3conv $jsonPath $pluginPath
    if ($LASTEXITCODE -ne 0) { throw "tes3conv failed to build $pluginPath" }
}

if (-not (Test-Path -LiteralPath $tes3conv)) { throw "tes3conv was not found at $tes3conv" }
$coreCharacterJson = Join-Path $converted 'StarwindRemasteredV1.15.character-compatible.json'
$patchCharacterJson = Join-Path $converted 'StarwindRemasteredPatch.character-compatible.json'
if (-not (Test-Path -LiteralPath $coreCharacterJson) -or -not (Test-Path -LiteralPath $patchCharacterJson)) {
    throw 'Run Build-CharacterCompatibleStarwind.ps1 before this body-part build.'
}
Write-Output 'Body-part stage: reading the audited collision IDs.'

# The reports are generated from the official masters by Analyze-StarwindOverrides.
# Reading them avoids keeping the 174 MB Morrowind JSON conversion in memory while
# the two Starwind plugins are being rebuilt.
$bodypartMap = [ordered]@{}
foreach ($reportName in @('overridden-records.csv', 'patch-overridden-records.csv')) {
    $reportPath = Join-Path $projectRoot "reports\$reportName"
    if (-not (Test-Path -LiteralPath $reportPath)) { throw "Missing override report: $reportPath" }
    foreach ($row in Import-Csv -LiteralPath $reportPath | Where-Object { $_.RecordType -eq 'Bodypart' }) {
        $bodypartMap[$row.Id] = Get-NewBodypartId $row.Id
    }
}
Write-Output "Body-part stage: mapped $($bodypartMap.Count) conflicting IDs."

$core = Read-Plugin $coreCharacterJson
$coreRecords = @($core | Select-Object -Skip 1)

if ($bodypartMap.Count -eq 0) { throw 'No overridden body parts were found.' }
if (@($bodypartMap.Values | Select-Object -Unique).Count -ne $bodypartMap.Count) { throw 'Body-part ID mapping is not unique.' }

function Apply-BodypartMap($records, [string]$label) {
    $renameExpected = @($records | Where-Object { $_.type -eq 'Bodypart' -and $bodypartMap.Contains($_.id) }).Count
    $headExpected = @($records | Where-Object { $_.type -eq 'Npc' -and $bodypartMap.Contains($_.head) }).Count
    $hairExpected = @($records | Where-Object { $_.type -eq 'Npc' -and $bodypartMap.Contains($_.hair) }).Count
    $bipedExpected = 0
    foreach ($record in $records | Where-Object { $_.type -in @('Armor', 'Clothing') }) {
        foreach ($part in $record.biped_objects) {
            if ($bodypartMap.Contains($part.male_bodypart)) { $bipedExpected++ }
            if ($bodypartMap.Contains($part.female_bodypart)) { $bipedExpected++ }
        }
    }

    $renamed = 0
    foreach ($record in $records | Where-Object { $_.type -eq 'Bodypart' }) {
        if ($bodypartMap.Contains($record.id)) {
            $record.id = $bodypartMap[$record.id]
            $renamed++
        }
    }
    Assert-Count "$label body-part IDs" $renamed $renameExpected
    Assert-Count "$label NPC heads" (Remap-Field $records 'Npc' 'head' $bodypartMap) $headExpected
    Assert-Count "$label NPC hair" (Remap-Field $records 'Npc' 'hair' $bodypartMap) $hairExpected
    Assert-Count "$label armor/clothing body parts" (Remap-BipedObjects $records $bodypartMap) $bipedExpected

    $remainingBodyparts = @($records | Where-Object { $_.type -eq 'Bodypart' -and $bodypartMap.Contains($_.id) })
    $remainingHeads = @($records | Where-Object { $_.type -eq 'Npc' -and $bodypartMap.Contains($_.head) })
    $remainingHair = @($records | Where-Object { $_.type -eq 'Npc' -and $bodypartMap.Contains($_.hair) })
    if ($remainingBodyparts.Count -ne 0 -or $remainingHeads.Count -ne 0 -or $remainingHair.Count -ne 0) {
        throw "$label still contains original overridden body-part IDs."
    }
}

Apply-BodypartMap $coreRecords 'Core'
$coreOutputJson = Join-Path $converted 'StarwindRemasteredV1.15.bodypart-compatible.json'
Write-PluginJson $core $coreOutputJson
$coreBuild = Join-Path $buildDirectory 'StarwindRemasteredV1.15.esm'
Build-Plugin $coreOutputJson $coreBuild
$coreBytes = (Get-Item -LiteralPath $coreBuild).Length

$coreRecords = $null
$core = $null
[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()

$patch = Read-Plugin $patchCharacterJson
$patchRecords = @($patch | Select-Object -Skip 1)
Apply-BodypartMap $patchRecords 'Patch'
$updatedMaster = 0
foreach ($master in $patch[0].masters) {
    if ($master[0] -eq 'StarwindRemasteredV1.15.esm') {
        $master[1] = $coreBytes
        $updatedMaster++
    }
}
Assert-Count 'Patch core-master byte count' $updatedMaster 1
$patchOutputJson = Join-Path $converted 'StarwindRemasteredPatch.bodypart-compatible.json'
Write-PluginJson $patch $patchOutputJson
$patchBuild = Join-Path $buildDirectory 'StarwindRemasteredPatch.esm'
Build-Plugin $patchOutputJson $patchBuild

[PSCustomObject]@{
    CorePlugin = $coreBuild
    PatchPlugin = $patchBuild
    IsolatedBodyparts = $bodypartMap.Count
    CoreBytes = $coreBytes
    PatchBytes = (Get-Item -LiteralPath $patchBuild).Length
} | Format-List
