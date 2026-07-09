[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$umoRoot = Split-Path -Parent $projectRoot
$converted = Join-Path $projectRoot 'converted'
$reports = Join-Path $projectRoot 'reports'
$buildDirectory = Join-Path $projectRoot 'build\Data Files'
$tes3conv = Join-Path $umoRoot 'starwind-modded\tes3conv.exe'
$python = 'C:\Users\REPTILE\AppData\Local\Programs\Python\Python312\python.exe'

foreach ($path in @($tes3conv, $python, (Join-Path $converted 'Morrowind.json'), (Join-Path $converted 'Tribunal.json'), (Join-Path $converted 'Bloodmoon.json'))) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required input was not found: $path" }
}
$coreInput = Join-Path $converted 'StarwindRemasteredV1.15.dialogue-compatible.json'
$patchInput = Join-Path $converted 'StarwindRemasteredPatch.dialogue-compatible.json'
if (-not (Test-Path -LiteralPath $coreInput) -or -not (Test-Path -LiteralPath $patchInput)) {
    throw 'Run Build-DialogueCompatibleStarwind.ps1 before this record-ID build.'
}

$coreOutput = Join-Path $converted 'StarwindRemasteredV1.15.record-compatible.json'
$patchOutput = Join-Path $converted 'StarwindRemasteredPatch.record-compatible.json'
& $python (Join-Path $PSScriptRoot 'Migrate-StarwindRecordIds.py') `
    --core-input $coreInput --patch-input $patchInput `
    --master (Join-Path $converted 'Morrowind.json') `
    --master (Join-Path $converted 'Tribunal.json') `
    --master (Join-Path $converted 'Bloodmoon.json') `
    --core-output $coreOutput --patch-output $patchOutput `
    --map-output (Join-Path $reports 'record-id-migration-map.json')
if ($LASTEXITCODE -ne 0) { throw 'Record ID migration failed.' }

New-Item -ItemType Directory -Force -Path $buildDirectory | Out-Null
$coreBuild = Join-Path $buildDirectory 'StarwindRemasteredV1.15.esm'
$coreBuildStarted = Get-Date
& $tes3conv $coreOutput $coreBuild
if ($LASTEXITCODE -ne 0) { throw 'tes3conv could not build the record-compatible core ESM.' }
for ($attempt = 0; $attempt -lt 60; $attempt++) {
    $coreInfo = Get-Item -LiteralPath $coreBuild
    if ($coreInfo.LastWriteTime -ge $coreBuildStarted) {
        $size = $coreInfo.Length
        Start-Sleep -Seconds 1
        if ((Get-Item -LiteralPath $coreBuild).Length -eq $size) { break }
    }
    Start-Sleep -Seconds 1
}
if ($attempt -eq 60) { throw 'Timed out waiting for tes3conv to finish writing the core ESM.' }
$coreBytes = (Get-Item -LiteralPath $coreBuild).Length

$patch = Get-Content -Raw -LiteralPath $patchOutput | ConvertFrom-Json
$masterUpdated = 0
foreach ($master in $patch[0].masters) {
    if ($master[0] -eq 'StarwindRemasteredV1.15.esm') { $master[1] = $coreBytes; $masterUpdated++ }
}
if ($masterUpdated -ne 1) { throw "Expected one core master byte-count update; made $masterUpdated." }
[System.IO.File]::WriteAllText($patchOutput, ($patch | ConvertTo-Json -Depth 100), [System.Text.UTF8Encoding]::new($false))
$patchBuild = Join-Path $buildDirectory 'StarwindRemasteredPatch.esm'
& $tes3conv $patchOutput $patchBuild
if ($LASTEXITCODE -ne 0) { throw 'tes3conv could not build the record-compatible patch ESM.' }

$map = Get-Content -Raw -LiteralPath (Join-Path $reports 'record-id-migration-map.json') | ConvertFrom-Json
[PSCustomObject]@{
    CorePlugin = $coreBuild
    PatchPlugin = $patchBuild
    NamespacedRecords = $map.recordIds.PSObject.Properties.Count
    CoreBytes = $coreBytes
    PatchBytes = (Get-Item -LiteralPath $patchBuild).Length
} | Format-List
