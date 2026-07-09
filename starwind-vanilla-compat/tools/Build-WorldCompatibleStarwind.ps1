[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$umoRoot = Split-Path -Parent $projectRoot
$converted = Join-Path $projectRoot 'converted'
$buildDirectory = Join-Path $projectRoot 'build\Data Files'
$reports = Join-Path $projectRoot 'reports'
$tes3conv = Join-Path $umoRoot 'starwind-modded\tes3conv.exe'
$python = 'C:\Users\REPTILE\AppData\Local\Programs\Python\Python312\python.exe'

function Build-Plugin([string]$jsonPath, [string]$pluginPath) {
    & $tes3conv $jsonPath $pluginPath
    if ($LASTEXITCODE -ne 0) { throw "tes3conv failed to build $pluginPath" }
}

foreach ($path in @($tes3conv, $python, (Join-Path $converted 'Morrowind.json'))) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required input was not found: $path" }
}
$coreInput = Join-Path $converted 'StarwindRemasteredV1.15.script-global-compatible.json'
$patchInput = Join-Path $converted 'StarwindRemasteredPatch.script-global-compatible.json'
if (-not (Test-Path -LiteralPath $coreInput) -or -not (Test-Path -LiteralPath $patchInput)) {
    throw 'Run Build-ScriptGlobalCompatibleStarwind.ps1 before this world build.'
}

$coreOutput = Join-Path $converted 'StarwindRemasteredV1.15.world-compatible.json'
$patchOutput = Join-Path $converted 'StarwindRemasteredPatch.world-compatible.json'
$mapOutput = Join-Path $reports 'world-migration-map.json'
& $python (Join-Path $PSScriptRoot 'Migrate-StarwindWorld.py') '--core-input' $coreInput '--patch-input' $patchInput '--morrowind-master' (Join-Path $converted 'Morrowind.json') '--reports' $reports '--core-output' $coreOutput '--patch-output' $patchOutput '--map-output' $mapOutput
if ($LASTEXITCODE -ne 0) { throw 'Migrate-StarwindWorld.py failed.' }

$coreBuild = Join-Path $buildDirectory 'StarwindRemasteredV1.15.esm'
Build-Plugin $coreOutput $coreBuild
$coreBytes = (Get-Item -LiteralPath $coreBuild).Length

$patch = Get-Content -Raw -LiteralPath $patchOutput | ConvertFrom-Json
$masterUpdated = 0
foreach ($master in $patch[0].masters) {
    if ($master[0] -eq 'StarwindRemasteredV1.15.esm') { $master[1] = $coreBytes; $masterUpdated++ }
}
if ($masterUpdated -ne 1) { throw "Expected one core master byte-count update; made $masterUpdated." }
$patchJson = $patch | ConvertTo-Json -Depth 100
[System.IO.File]::WriteAllText($patchOutput, $patchJson, [System.Text.UTF8Encoding]::new($false))
$patchBuild = Join-Path $buildDirectory 'StarwindRemasteredPatch.esm'
Build-Plugin $patchOutput $patchBuild

$map = Get-Content -Raw -LiteralPath $mapOutput | ConvertFrom-Json
[PSCustomObject]@{
    CorePlugin = $coreBuild
    PatchPlugin = $patchBuild
    OffsetCellsX = $map.offsetCells.x
    OffsetCellsY = $map.offsetCells.y
    RenamedInteriorCells = $map.interiorCellNames.PSObject.Properties.Count
    ClonedMorrowindLandRecords = $map.clonedMorrowindLandRecords
    CoreBytes = $coreBytes
    PatchBytes = (Get-Item -LiteralPath $patchBuild).Length
} | Format-List
