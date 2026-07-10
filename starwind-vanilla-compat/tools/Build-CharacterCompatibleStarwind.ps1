[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$umoRoot = Split-Path -Parent $projectRoot
$tes3conv = Join-Path $umoRoot 'starwind-modded\tes3conv.exe'
$python = 'C:\Users\REPTILE\AppData\Local\Programs\Python\Python312\python.exe'
$converted = Join-Path $projectRoot 'converted'
$buildDirectory = Join-Path $projectRoot 'build\Data Files'

$raceMap = [ordered]@{
    'Argonian' = 'SW_Gungan'; 'Breton' = 'SW_Tarisian'; 'Dark Elf' = 'SW_Duros'; 'High Elf' = 'SW_Twilek'
    'Imperial' = 'SW_Coruscanti'; 'Khajiit' = 'SW_Cathar'; 'Nord' = 'SW_Mandalorian'; 'Orc' = 'SW_Rodian'
    'Redguard' = 'SW_Lothalite'; 'Wood Elf' = 'SW_Droid'
}
$classMap = [ordered]@{
    'Acrobat' = 'SW_Acrobat'; 'Agent' = 'SW_Agent'; 'Archer' = 'SW_Archer'; 'Assassin' = 'SW_Assassin'
    'Barbarian' = 'SW_Barbarian'; 'Bard' = 'SW_Bard'; 'Battlemage' = 'SW_Battlemage'; 'Crusader' = 'SW_Crusader'
    'Healer' = 'SW_Healer'; 'Knight' = 'SW_Knight'; 'Mage' = 'SW_Mage'; 'Monk' = 'SW_Monk'
    'Nightblade' = 'SW_Nightblade'; 'Pilgrim' = 'SW_Pilgrim'; 'Rogue' = 'SW_Rogue'; 'Scout' = 'SW_Scout'
    'Smuggler' = 'SW_Smuggler'; 'Sorcerer' = 'SW_ForceSensitive'; 'Spellsword' = 'SW_Spellsword'
    'Thief' = 'SW_Thief'; 'Warrior' = 'SW_Warrior'; 'Witchhunter' = 'SW_Witchhunter'
}
$birthsignMap = [ordered]@{
    "Beggar's Nose" = 'SW_TheTower'; 'Blessed Touch Sign' = 'SW_TheRitual'; 'Charioteer' = 'SW_TheSteed'
    'Elfborn' = 'SW_TheApprentice'; 'Fay' = 'SW_TheMage'; 'Hara' = 'SW_TheThief'; "Lady's Favor" = 'SW_TheLady'
    'Mooncalf' = 'SW_TheLover'; 'Moonshadow Sign' = 'SW_TheShadow'; 'Star-Cursed' = 'SW_TheSerpent'
    'Trollkin' = 'SW_TheLord'; 'Warwyrd' = 'SW_TheWarrior'; 'Wombburned' = 'SW_TheAtronach'
}

function Read-Plugin([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing converted plugin: $path" }
    return Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
}

function Rename-RecordIds($records, [string]$recordType, $idMap) {
    $changed = 0
    foreach ($record in $records | Where-Object { $_.type -eq $recordType }) {
        if ($idMap.Contains($record.id)) {
            $record.id = $idMap[$record.id]
            $changed++
        }
    }
    return $changed
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

function Remap-StarwindBodypartRaceLinks($records, $idMap) {
    $changed = 0
    foreach ($record in $records | Where-Object { $_.type -eq 'Bodypart' -and $_.id -like 'SW_*' }) {
        if ($record.PSObject.Properties.Name -contains 'race') {
            $value = $record.race
            if ($idMap.Contains($value)) {
                $record.race = $idMap[$value]
                $changed++
            }
        }
    }
    return $changed
}

function Assert-Count([string]$label, [int]$actual, [int]$expected) {
    if ($actual -ne $expected) { throw "$label expected $expected changes; made $actual." }
}

function Assert-NoOriginalIds($records, [string]$recordType, $idMap) {
    $remaining = @($records | Where-Object { $_.type -eq $recordType -and $idMap.Contains($_.id) })
    if ($remaining.Count -ne 0) { throw "$recordType records still use original master IDs." }
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
New-Item -ItemType Directory -Force -Path $buildDirectory | Out-Null

$core = Read-Plugin (Join-Path $converted 'StarwindRemasteredV1.15.json')
$coreRecords = @($core | Select-Object -Skip 1)
Assert-Count 'Core race IDs' (Rename-RecordIds $coreRecords 'Race' $raceMap) 10
Assert-Count 'Core NPC race links' (Remap-Field $coreRecords 'Npc' 'race' $raceMap) 519
$coreBodypartRaceLinks = Remap-StarwindBodypartRaceLinks $coreRecords $raceMap
Write-Host Core Starwind bodypart race links remapped: $coreBodypartRaceLinks
Assert-Count 'Core class IDs' (Rename-RecordIds $coreRecords 'Class' $classMap) 22
Assert-Count 'Core NPC class links' (Remap-Field $coreRecords 'Npc' 'class' $classMap) 370
Assert-Count 'Core dialogue class filters' (Remap-Field $coreRecords 'DialogueInfo' 'speaker_class' $classMap) 3
Assert-Count 'Core birthsign IDs' (Rename-RecordIds $coreRecords 'Birthsign' $birthsignMap) 13

foreach ($record in $coreRecords | Where-Object { $_.type -eq 'Birthsign' -and $_.id -like 'SW_*' }) {
    $record.name = "Starwind - $($record.name)"
}
Assert-NoOriginalIds $coreRecords 'Race' $raceMap
Assert-NoOriginalIds $coreRecords 'Class' $classMap
Assert-NoOriginalIds $coreRecords 'Birthsign' $birthsignMap

$coreOutputJson = Join-Path $converted 'StarwindRemasteredV1.15.character-compatible.json'
Write-PluginJson $core $coreOutputJson
& $python (Join-Path $PSScriptRoot 'Migrate-StarwindRaceBodyparts.py') '--plugin' $coreOutputJson '--master' (Join-Path $converted 'Morrowind.json') '--output' $coreOutputJson
if ($LASTEXITCODE -ne 0) { throw 'Migrate-StarwindRaceBodyparts.py failed for core.' }
$coreBuild = Join-Path $buildDirectory 'StarwindRemasteredV1.15.esm'
Build-Plugin $coreOutputJson $coreBuild
$coreBytes = (Get-Item -LiteralPath $coreBuild).Length

$patch = Read-Plugin (Join-Path $converted 'StarwindRemasteredPatch.json')
$patchRecords = @($patch | Select-Object -Skip 1)
Assert-Count 'Patch race IDs' (Rename-RecordIds $patchRecords 'Race' $raceMap) 10
Assert-Count 'Patch NPC race links' (Remap-Field $patchRecords 'Npc' 'race' $raceMap) 718
$patchBodypartRaceLinks = Remap-StarwindBodypartRaceLinks $patchRecords $raceMap
Write-Host Patch Starwind bodypart race links remapped: $patchBodypartRaceLinks
Assert-Count 'Patch class IDs' (Rename-RecordIds $patchRecords 'Class' $classMap) 2
Assert-Count 'Patch NPC class links' (Remap-Field $patchRecords 'Npc' 'class' $classMap) 612
Assert-Count 'Patch dialogue class filters' (Remap-Field $patchRecords 'DialogueInfo' 'speaker_class' $classMap) 203
Assert-NoOriginalIds $patchRecords 'Race' $raceMap
Assert-NoOriginalIds $patchRecords 'Class' $classMap

$updatedMaster = 0
foreach ($master in $patch[0].masters) {
    if ($master[0] -eq 'StarwindRemasteredV1.15.esm') {
        $master[1] = $coreBytes
        $updatedMaster++
    }
}
Assert-Count 'Patch core-master byte count' $updatedMaster 1

$patchOutputJson = Join-Path $converted 'StarwindRemasteredPatch.character-compatible.json'
Write-PluginJson $patch $patchOutputJson
$patchBuild = Join-Path $buildDirectory 'StarwindRemasteredPatch.esm'
Build-Plugin $patchOutputJson $patchBuild

[PSCustomObject]@{
    CorePlugin = $coreBuild
    CoreBytes = $coreBytes
    PatchPlugin = $patchBuild
    PatchBytes = (Get-Item -LiteralPath $patchBuild).Length
    MigratedRaces = 10
    MigratedClasses = 22
    MigratedBirthsigns = 13
} | Format-List
