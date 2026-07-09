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

function Write-PluginJson($plugin, [string]$path) {
    $json = $plugin | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))
}

function Build-Plugin([string]$jsonPath, [string]$pluginPath) {
    & $tes3conv $jsonPath $pluginPath
    if ($LASTEXITCODE -ne 0) { throw "tes3conv failed to build $pluginPath" }
}

function Assert-Equal([string]$label, [int]$actual, [int]$expected) {
    if ($actual -ne $expected) { throw "$label expected $expected changes; made $actual." }
}

function Remap-Books($records, $bookMap, [string]$label) {
    $bookExpected = @($records | Where-Object { $_.type -eq 'Book' -and $bookMap.Contains($_.id) }).Count
    $npcExpected = 0
    foreach ($npc in $records | Where-Object { $_.type -eq 'Npc' }) {
        foreach ($entry in $npc.inventory) { if ($bookMap.Contains($entry[1])) { $npcExpected++ } }
    }
    $containerExpected = 0
    foreach ($container in $records | Where-Object { $_.type -eq 'Container' }) {
        foreach ($entry in $container.inventory) { if ($bookMap.Contains($entry[1])) { $containerExpected++ } }
    }
    $leveledExpected = 0
    foreach ($list in $records | Where-Object { $_.type -eq 'LeveledItem' }) {
        foreach ($entry in $list.items) { if ($bookMap.Contains($entry[0])) { $leveledExpected++ } }
    }
    $cellExpected = 0
    foreach ($cell in $records | Where-Object { $_.type -eq 'Cell' }) {
        foreach ($reference in $cell.references) { if ($bookMap.Contains($reference.id)) { $cellExpected++ } }
    }

    $bookChanged = 0
    foreach ($record in $records | Where-Object { $_.type -eq 'Book' }) {
        if ($bookMap.Contains($record.id)) { $record.id = $bookMap[$record.id]; $bookChanged++ }
    }
    $npcChanged = 0
    foreach ($npc in $records | Where-Object { $_.type -eq 'Npc' }) {
        foreach ($entry in $npc.inventory) {
            if ($bookMap.Contains($entry[1])) { $entry[1] = $bookMap[$entry[1]]; $npcChanged++ }
        }
    }
    $containerChanged = 0
    foreach ($container in $records | Where-Object { $_.type -eq 'Container' }) {
        foreach ($entry in $container.inventory) {
            if ($bookMap.Contains($entry[1])) { $entry[1] = $bookMap[$entry[1]]; $containerChanged++ }
        }
    }
    $leveledChanged = 0
    foreach ($list in $records | Where-Object { $_.type -eq 'LeveledItem' }) {
        foreach ($entry in $list.items) {
            if ($bookMap.Contains($entry[0])) { $entry[0] = $bookMap[$entry[0]]; $leveledChanged++ }
        }
    }
    $cellChanged = 0
    foreach ($cell in $records | Where-Object { $_.type -eq 'Cell' }) {
        foreach ($reference in $cell.references) {
            if ($bookMap.Contains($reference.id)) { $reference.id = $bookMap[$reference.id]; $cellChanged++ }
        }
    }

    Assert-Equal "$label Book records" $bookChanged $bookExpected
    Assert-Equal "$label NPC book references" $npcChanged $npcExpected
    Assert-Equal "$label container book references" $containerChanged $containerExpected
    Assert-Equal "$label leveled-item book references" $leveledChanged $leveledExpected
    Assert-Equal "$label cell book references" $cellChanged $cellExpected
}

if (-not (Test-Path -LiteralPath $tes3conv)) { throw "tes3conv was not found at $tes3conv" }
$coreInput = Join-Path $converted 'StarwindRemasteredV1.15.npc-compatible.json'
$patchInput = Join-Path $converted 'StarwindRemasteredPatch.npc-compatible.json'
if (-not (Test-Path -LiteralPath $coreInput) -or -not (Test-Path -LiteralPath $patchInput)) {
    throw 'Run Build-NpcCompatibleStarwind.ps1 before this book build.'
}

$bookMap = [ordered]@{}
foreach ($reportName in @('overridden-records.csv', 'patch-overridden-records.csv')) {
    foreach ($row in Import-Csv -LiteralPath (Join-Path $projectRoot "reports\$reportName") | Where-Object { $_.RecordType -eq 'Book' }) {
        $newId = "SW_$($row.Id)"
        if ($newId.Length -gt 32) { throw "Renamed Book ID exceeds TES3's 32-character limit: $newId" }
        $bookMap[$row.Id] = $newId
    }
}
if ($bookMap.Count -eq 0) { throw 'No overridden Book IDs were found.' }

$core = Read-Plugin $coreInput
Remap-Books @($core | Select-Object -Skip 1) $bookMap 'Core'
$coreOutput = Join-Path $converted 'StarwindRemasteredV1.15.book-compatible.json'
Write-PluginJson $core $coreOutput
$coreBuild = Join-Path $buildDirectory 'StarwindRemasteredV1.15.esm'
Build-Plugin $coreOutput $coreBuild
$coreBytes = (Get-Item -LiteralPath $coreBuild).Length

$core = $null
[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()

$patch = Read-Plugin $patchInput
Remap-Books @($patch | Select-Object -Skip 1) $bookMap 'Patch'
$masterUpdated = 0
foreach ($master in $patch[0].masters) {
    if ($master[0] -eq 'StarwindRemasteredV1.15.esm') { $master[1] = $coreBytes; $masterUpdated++ }
}
Assert-Equal 'Patch core-master byte count' $masterUpdated 1
$patchOutput = Join-Path $converted 'StarwindRemasteredPatch.book-compatible.json'
Write-PluginJson $patch $patchOutput
$patchBuild = Join-Path $buildDirectory 'StarwindRemasteredPatch.esm'
Build-Plugin $patchOutput $patchBuild

[PSCustomObject]@{
    CorePlugin = $coreBuild
    PatchPlugin = $patchBuild
    IsolatedBooks = $bookMap.Count
    CoreBytes = $coreBytes
    PatchBytes = (Get-Item -LiteralPath $patchBuild).Length
} | Format-List
