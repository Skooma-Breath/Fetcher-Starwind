[CmdletBinding()]
param(
    [string]$InputJson = (Join-Path (Split-Path -Parent $PSScriptRoot) 'converted\StarwindRemasteredV1.15.json'),
    [string]$OutputJson = (Join-Path (Split-Path -Parent $PSScriptRoot) 'converted\StarwindRemasteredV1.15.vanilla-compatible.json'),
    [int]$ExpectedNpcUpdates = 519,
    [long]$UpdatedCoreMasterBytes = 0,
    [string]$OutputPluginName = 'StarwindRemasteredV1.15.esm',
    [switch]$BuildPlugin
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$umoRoot = Split-Path -Parent $projectRoot
$sourceRoot = if ($env:FETCHER_STARWIND_SOURCE_ROOT) { $env:FETCHER_STARWIND_SOURCE_ROOT } else { $umoRoot }
$tes3conv = Join-Path $sourceRoot 'starwind-modded\tes3conv.exe'

# The original ID is a vanilla race record. The new ID describes the Starwind race
# occupying that slot, so vanilla selection and Starwind NPC assignments can coexist.
$raceMap = [ordered]@{
    'Argonian' = 'SW_Gungan'
    'Breton' = 'SW_Tarisian'
    'Dark Elf' = 'SW_Duros'
    'High Elf' = 'SW_Twilek'
    'Imperial' = 'SW_Coruscanti'
    'Khajiit' = 'SW_Cathar'
    'Nord' = 'SW_Mandalorian'
    'Orc' = 'SW_Rodian'
    'Redguard' = 'SW_Lothalite'
    'Wood Elf' = 'SW_Droid'
}

if (-not (Test-Path -LiteralPath $InputJson)) { throw "Missing converted Starwind master: $InputJson" }
$plugin = Get-Content -Raw -Encoding UTF8 -LiteralPath $InputJson | ConvertFrom-Json
$records = @($plugin | Select-Object -Skip 1)

$renamedRaces = 0
foreach ($record in $records | Where-Object { $_.type -eq 'Race' }) {
    if ($raceMap.Contains($record.id)) {
        $record.id = $raceMap[$record.id]
        $renamedRaces++
    }
}

$updatedNpcs = 0
foreach ($record in $records | Where-Object { $_.type -eq 'Npc' }) {
    if ($raceMap.Contains($record.race)) {
        $record.race = $raceMap[$record.race]
        $updatedNpcs++
    }
}

if ($renamedRaces -ne $raceMap.Count) { throw "Expected to rename $($raceMap.Count) races; renamed $renamedRaces." }
if ($ExpectedNpcUpdates -ge 0 -and $updatedNpcs -ne $ExpectedNpcUpdates) { throw "Expected to update $ExpectedNpcUpdates Starwind NPC race references; updated $updatedNpcs." }

$remainingVanillaRaceIds = @($records | Where-Object { $_.type -eq 'Race' -and $raceMap.Contains($_.id) })
if ($remainingVanillaRaceIds.Count -ne 0) { throw 'Vanilla race IDs remain in the compatible Starwind master.' }
$remainingNpcReferences = @($records | Where-Object { $_.type -eq 'Npc' -and $raceMap.Contains($_.race) })
if ($remainingNpcReferences.Count -ne 0) { throw 'Starwind NPCs still reference overridden vanilla race IDs.' }

if ($UpdatedCoreMasterBytes -gt 0) {
    $updatedMasters = 0
    foreach ($master in $plugin[0].masters) {
        if ($master[0] -eq 'StarwindRemasteredV1.15.esm') {
            $master[1] = $UpdatedCoreMasterBytes
            $updatedMasters++
        }
    }
    if ($updatedMasters -ne 1) { throw "Expected to update one StarwindRemasteredV1.15.esm master reference; updated $updatedMasters." }
}

$jsonText = $plugin | ConvertTo-Json -Depth 100
[System.IO.File]::WriteAllText($OutputJson, $jsonText, [System.Text.UTF8Encoding]::new($false))
Write-Output "Renamed $renamedRaces races and updated $updatedNpcs NPC race references."

if ($BuildPlugin) {
    if (-not (Test-Path -LiteralPath $tes3conv)) { throw "tes3conv was not found at $tes3conv" }
    $buildDirectory = Join-Path $projectRoot 'build\Data Files'
    New-Item -ItemType Directory -Force -Path $buildDirectory | Out-Null
    $buildPath = Join-Path $buildDirectory $OutputPluginName
    & $tes3conv $OutputJson $buildPath
    if ($LASTEXITCODE -ne 0) { throw 'tes3conv failed to build the compatible Starwind master.' }
    Get-Item -LiteralPath $buildPath | Select-Object FullName, Length
}
