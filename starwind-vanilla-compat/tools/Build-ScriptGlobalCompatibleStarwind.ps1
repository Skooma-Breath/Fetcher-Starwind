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
$coreInput = Join-Path $converted 'StarwindRemasteredV1.15.asset-compatible.json'
$patchInput = Join-Path $converted 'StarwindRemasteredPatch.asset-compatible.json'
$coreOutput = Join-Path $converted 'StarwindRemasteredV1.15.script-global-compatible.json'
$patchOutput = Join-Path $converted 'StarwindRemasteredPatch.script-global-compatible.json'

foreach ($path in @($tes3conv, $python, $coreInput, $patchInput, (Join-Path $reports 'overridden-records.csv'), (Join-Path $reports 'patch-overridden-records.csv'))) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required input was not found: $path" }
}

& $python (Join-Path $PSScriptRoot 'Migrate-StarwindScripts.py') `
    --core-input $coreInput --patch-input $patchInput --reports $reports `
    --core-output $coreOutput --patch-output $patchOutput `
    --map-output (Join-Path $reports 'script-global-migration-map.json')
if ($LASTEXITCODE -ne 0) { throw 'Script/global migration failed.' }

New-Item -ItemType Directory -Force -Path $buildDirectory | Out-Null
$coreBuild = Join-Path $buildDirectory 'StarwindRemasteredV1.15.esm'
& $tes3conv $coreOutput $coreBuild
if ($LASTEXITCODE -ne 0) { throw 'tes3conv could not build the script/global-compatible core ESM.' }
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
if ($LASTEXITCODE -ne 0) { throw 'tes3conv could not build the script/global-compatible patch ESM.' }

$map = Get-Content -Raw -LiteralPath (Join-Path $reports 'script-global-migration-map.json') | ConvertFrom-Json
[PSCustomObject]@{
    CorePlugin = $coreBuild
    PatchPlugin = $patchBuild
    IsolatedScripts = $map.scriptIds.PSObject.Properties.Count
    IsolatedGlobalVariables = $map.globalIds.PSObject.Properties.Count
    RemovedForeignStartScripts = @($map.removedStartScriptIds).Count
    CoreBytes = $coreBytes
    PatchBytes = (Get-Item -LiteralPath $patchBuild).Length
} | Format-List
