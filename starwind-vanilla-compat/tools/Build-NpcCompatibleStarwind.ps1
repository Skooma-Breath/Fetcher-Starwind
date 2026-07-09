[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$umoRoot = Split-Path -Parent $projectRoot
$converted = Join-Path $projectRoot 'converted'
$buildDirectory = Join-Path $projectRoot 'build\Data Files'
$tes3conv = Join-Path $umoRoot 'starwind-modded\tes3conv.exe'

function Read-Plugin([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing converted plugin: $path" }
    return Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
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

function Remap-NpcIds($records, $npcMap, [string]$label) {
    $npcExpected = @($records | Where-Object { $_.type -eq 'Npc' -and $npcMap.Contains($_.id) }).Count
    $cellExpected = 0
    foreach ($cell in $records | Where-Object { $_.type -eq 'Cell' }) {
        foreach ($reference in $cell.references) {
            if ($npcMap.Contains($reference.id)) { $cellExpected++ }
        }
    }
    $dialogueExpected = @($records | Where-Object { $_.type -eq 'DialogueInfo' -and $npcMap.Contains($_.speaker_id) }).Count
    $leveledExpected = 0
    foreach ($record in $records | Where-Object { $_.type -eq 'LeveledCreature' }) {
        foreach ($entry in $record.creatures) {
            if ($npcMap.Contains($entry[0])) { $leveledExpected++ }
        }
    }

    $renamed = 0
    foreach ($record in $records | Where-Object { $_.type -eq 'Npc' }) {
        if ($npcMap.Contains($record.id)) {
            $record.id = $npcMap[$record.id]
            $renamed++
        }
    }

    $cellUpdated = 0
    foreach ($cell in $records | Where-Object { $_.type -eq 'Cell' }) {
        foreach ($reference in $cell.references) {
            if ($npcMap.Contains($reference.id)) {
                $reference.id = $npcMap[$reference.id]
                $cellUpdated++
            }
        }
    }

    $dialogueUpdated = 0
    foreach ($record in $records | Where-Object { $_.type -eq 'DialogueInfo' }) {
        if ($npcMap.Contains($record.speaker_id)) {
            $record.speaker_id = $npcMap[$record.speaker_id]
            $dialogueUpdated++
        }
    }

    $leveledUpdated = 0
    foreach ($record in $records | Where-Object { $_.type -eq 'LeveledCreature' }) {
        foreach ($entry in $record.creatures) {
            if ($npcMap.Contains($entry[0])) {
                $entry[0] = $npcMap[$entry[0]]
                $leveledUpdated++
            }
        }
    }

    Assert-Count "$label NPC records" $renamed $npcExpected
    Assert-Count "$label cell NPC references" $cellUpdated $cellExpected
    Assert-Count "$label dialogue NPC references" $dialogueUpdated $dialogueExpected
    Assert-Count "$label leveled-creature NPC references" $leveledUpdated $leveledExpected

    $remaining = @($records | Where-Object { $_.type -eq 'Npc' -and $npcMap.Contains($_.id) })
    if ($remaining.Count -ne 0) { throw "$label still contains overridden NPC IDs." }
}

if (-not (Test-Path -LiteralPath $tes3conv)) { throw "tes3conv was not found at $tes3conv" }
$coreInput = Join-Path $converted 'StarwindRemasteredV1.15.bodypart-compatible.json'
$patchInput = Join-Path $converted 'StarwindRemasteredPatch.bodypart-compatible.json'
if (-not (Test-Path -LiteralPath $coreInput) -or -not (Test-Path -LiteralPath $patchInput)) {
    throw 'Run Build-BodypartCompatibleStarwind.ps1 before this NPC build.'
}

$npcMap = [ordered]@{}
foreach ($reportName in @('overridden-records.csv', 'patch-overridden-records.csv')) {
    $reportPath = Join-Path $projectRoot "reports\$reportName"
    if (-not (Test-Path -LiteralPath $reportPath)) { throw "Missing override report: $reportPath" }
    foreach ($row in Import-Csv -LiteralPath $reportPath | Where-Object { $_.RecordType -eq 'Npc' }) {
        $newId = "SW_$($row.Id)"
        if ($newId.Length -gt 32) { throw "Renamed NPC ID exceeds TES3's 32-character limit: $newId" }
        $npcMap[$row.Id] = $newId
    }
}
if ($npcMap.Count -eq 0) { throw 'No overridden NPC IDs were found.' }
if (@($npcMap.Values | Select-Object -Unique).Count -ne $npcMap.Count) { throw 'NPC ID mapping is not unique.' }

$core = Read-Plugin $coreInput
$coreRecords = @($core | Select-Object -Skip 1)
Remap-NpcIds $coreRecords $npcMap 'Core'
$coreOutput = Join-Path $converted 'StarwindRemasteredV1.15.npc-compatible.json'
Write-PluginJson $core $coreOutput
$coreBuild = Join-Path $buildDirectory 'StarwindRemasteredV1.15.esm'
Build-Plugin $coreOutput $coreBuild
$coreBytes = (Get-Item -LiteralPath $coreBuild).Length

$coreRecords = $null
$core = $null
[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()

$patch = Read-Plugin $patchInput
$patchRecords = @($patch | Select-Object -Skip 1)
Remap-NpcIds $patchRecords $npcMap 'Patch'
$updatedMaster = 0
foreach ($master in $patch[0].masters) {
    if ($master[0] -eq 'StarwindRemasteredV1.15.esm') {
        $master[1] = $coreBytes
        $updatedMaster++
    }
}
Assert-Count 'Patch core-master byte count' $updatedMaster 1
$patchOutput = Join-Path $converted 'StarwindRemasteredPatch.npc-compatible.json'
Write-PluginJson $patch $patchOutput
$patchBuild = Join-Path $buildDirectory 'StarwindRemasteredPatch.esm'
Build-Plugin $patchOutput $patchBuild

[PSCustomObject]@{
    CorePlugin = $coreBuild
    PatchPlugin = $patchBuild
    IsolatedNpcs = $npcMap.Count
    CoreBytes = $coreBytes
    PatchBytes = (Get-Item -LiteralPath $patchBuild).Length
} | Format-List
