[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$UmoRoot = Split-Path -Parent $ProjectRoot
$SourceRoot = if ($env:FETCHER_STARWIND_SOURCE_ROOT) { $env:FETCHER_STARWIND_SOURCE_ROOT } else { $UmoRoot }
$Python = 'C:\Users\REPTILE\AppData\Local\Programs\Python\Python312\python.exe'
$Tes3Conv = Join-Path $SourceRoot 'starwind-modded\tes3conv.exe'
$converted = Join-Path $ProjectRoot 'converted'
$reports = Join-Path $ProjectRoot 'reports'
$dataFiles = Join-Path $ProjectRoot 'build\Data Files'
$coreInput = Join-Path $converted 'StarwindRemasteredV1.15.world-compatible.json'
$patchInput = Join-Path $converted 'StarwindRemasteredPatch.world-compatible.json'
$coreJson = Join-Path $converted 'StarwindRemasteredV1.15.dialogue-compatible.json'
$patchJson = Join-Path $converted 'StarwindRemasteredPatch.dialogue-compatible.json'

foreach ($path in @($Python, $Tes3Conv, $coreInput, $patchInput, (Join-Path $converted 'Morrowind.json'), (Join-Path $converted 'Tribunal.json'), (Join-Path $converted 'Bloodmoon.json'))) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required input not found: $path" }
}

& $Python (Join-Path $PSScriptRoot 'Migrate-StarwindDialogue.py') `
    --core-input $coreInput --patch-input $patchInput `
    --master (Join-Path $converted 'Morrowind.json') `
    --master (Join-Path $converted 'Tribunal.json') `
    --master (Join-Path $converted 'Bloodmoon.json') `
    --core-output $coreJson --patch-output $patchJson `
    --map-output (Join-Path $reports 'dialogue-migration-map.json')
if ($LASTEXITCODE -ne 0) { throw 'Dialogue migration failed.' }

New-Item -ItemType Directory -Force -Path $dataFiles | Out-Null
$coreEsm = Join-Path $dataFiles 'StarwindRemasteredV1.15.esm'
$patchEsm = Join-Path $dataFiles 'StarwindRemasteredPatch.esm'
& $Tes3Conv $coreJson $coreEsm
if ($LASTEXITCODE -ne 0) { throw 'tes3conv could not build the dialogue-compatible core ESM.' }

$coreSize = (Get-Item -LiteralPath $coreEsm).Length
$patch = Get-Content -LiteralPath $patchJson -Raw | ConvertFrom-Json
$masterUpdated = 0
foreach ($master in $patch[0].masters) {
    if ($master[0] -eq 'StarwindRemasteredV1.15.esm') { $master[1] = $coreSize; $masterUpdated++ }
}
if ($masterUpdated -ne 1) { throw "Expected one core master byte-count update; made $masterUpdated." }
$patchText = $patch | ConvertTo-Json -Depth 100
[System.IO.File]::WriteAllText($patchJson, $patchText, [System.Text.UTF8Encoding]::new($false))
& $Tes3Conv $patchJson $patchEsm
if ($LASTEXITCODE -ne 0) { throw 'tes3conv could not build the dialogue-compatible patch ESM.' }

Write-Host "Built dialogue-compatible Starwind masters in $dataFiles"
