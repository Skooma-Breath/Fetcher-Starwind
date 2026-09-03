[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$umoRoot = Split-Path -Parent $projectRoot
$sourceRoot = if ($env:FETCHER_STARWIND_SOURCE_ROOT) { $env:FETCHER_STARWIND_SOURCE_ROOT } else { $umoRoot }
$converted = Join-Path $projectRoot 'converted'
$reports = Join-Path $projectRoot 'reports'
$buildDirectory = Join-Path $projectRoot 'build\Data Files'
$tes3conv = Join-Path $sourceRoot 'starwind-modded\tes3conv.exe'
$python = 'C:\Users\REPTILE\AppData\Local\Programs\Python\Python312\python.exe'

$coreInput = Join-Path $converted 'StarwindRemasteredV1.15.record-compatible.json'
$patchInput = Join-Path $converted 'StarwindRemasteredPatch.record-compatible.json'
$tribunal = Join-Path $converted 'Tribunal.json'
foreach ($path in @($tes3conv, $python, $coreInput, $patchInput, $tribunal)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required input was not found: $path" }
}

$coreOutput = Join-Path $converted 'StarwindRemasteredV1.15.rhin-compatible.json'
$patchOutput = Join-Path $converted 'StarwindRemasteredPatch.rhin-compatible.json'
$reportOutput = Join-Path $reports 'rhin-mercenary-compatibility.json'
& $python (Join-Path $PSScriptRoot 'Apply-RhinMercenaryCompatibility.py') `
    --core-input $coreInput --patch-input $patchInput --tribunal $tribunal `
    --core-output $coreOutput --patch-output $patchOutput --report-output $reportOutput
if ($LASTEXITCODE -ne 0) { throw 'Rhin mercenary compatibility migration failed.' }

New-Item -ItemType Directory -Force -Path $buildDirectory | Out-Null
$coreBuild = Join-Path $buildDirectory 'StarwindRemasteredV1.15.esm'
& $tes3conv $coreOutput $coreBuild
if ($LASTEXITCODE -ne 0) { throw 'tes3conv could not build the Rhin-compatible core ESM.' }
$coreBytes = (Get-Item -LiteralPath $coreBuild).Length

$patch = Get-Content -Raw -Encoding UTF8 -LiteralPath $patchOutput | ConvertFrom-Json
$masterUpdated = 0
foreach ($master in $patch[0].masters) {
    if ($master[0] -eq 'StarwindRemasteredV1.15.esm') { $master[1] = $coreBytes; $masterUpdated++ }
}
if ($masterUpdated -ne 1) { throw "Expected one core master byte-count update; made $masterUpdated." }
[System.IO.File]::WriteAllText($patchOutput, ($patch | ConvertTo-Json -Depth 100), [System.Text.UTF8Encoding]::new($false))

$patchBuild = Join-Path $buildDirectory 'StarwindRemasteredPatch.esm'
& $tes3conv $patchOutput $patchBuild
if ($LASTEXITCODE -ne 0) { throw 'tes3conv could not build the Rhin-compatible patch ESM.' }

$report = Get-Content -Raw -Encoding UTF8 -LiteralPath $reportOutput | ConvertFrom-Json
[PSCustomObject]@{
    CorePlugin = $coreBuild
    PatchPlugin = $patchBuild
    CoreBytes = $coreBytes
    PatchBytes = (Get-Item -LiteralPath $patchBuild).Length
    RhinScript = 'SW_RhinMercenary'
    AnchorRefNum = $report.anchorRefNum
} | Format-List
