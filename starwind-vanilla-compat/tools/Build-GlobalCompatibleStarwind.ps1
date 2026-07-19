[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$umoRoot = Split-Path -Parent $projectRoot
$sourceRoot = if ($env:FETCHER_STARWIND_SOURCE_ROOT) { $env:FETCHER_STARWIND_SOURCE_ROOT } else { $umoRoot }
$converted = Join-Path $projectRoot 'converted'
$buildDirectory = Join-Path $projectRoot 'build\Data Files'
$tes3conv = Join-Path $sourceRoot 'starwind-modded\tes3conv.exe'

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
    if ($actual -ne $expected) { throw "$label expected $expected removals; made $actual." }
}

function Remove-GlobalOverrides($plugin, $settings, [string]$label) {
    $records = @($plugin | Select-Object -Skip 1)
    $settingCount = @($records | Where-Object { $_.type -eq 'GameSetting' -and $settings.Contains($_.id) }).Count
    $skillCount = @($records | Where-Object { $_.type -eq 'Skill' }).Count
    $effectCount = @($records | Where-Object { $_.type -eq 'MagicEffect' }).Count
    $kept = @($plugin[0]) + @($records | Where-Object {
        -not (($_.type -eq 'GameSetting' -and $settings.Contains($_.id)) -or $_.type -eq 'Skill' -or $_.type -eq 'MagicEffect')
    })
    Assert-Equal "$label GameSettings" ($records.Count - $kept.Count + 1 - $skillCount - $effectCount) $settingCount
    $kept[0].num_objects = $kept.Count - 1
    return ,$kept
}

if (-not (Test-Path -LiteralPath $tes3conv)) { throw "tes3conv was not found at $tes3conv" }
$coreInput = Join-Path $converted 'StarwindRemasteredV1.15.book-compatible.json'
$patchInput = Join-Path $converted 'StarwindRemasteredPatch.book-compatible.json'
if (-not (Test-Path -LiteralPath $coreInput) -or -not (Test-Path -LiteralPath $patchInput)) {
    throw 'Run Build-BookCompatibleStarwind.ps1 before this global-settings build.'
}

$settings = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($reportName in @('overridden-records.csv', 'patch-overridden-records.csv')) {
    foreach ($row in Import-Csv -LiteralPath (Join-Path $projectRoot "reports\$reportName") | Where-Object { $_.RecordType -eq 'GameSetting' }) {
        $settings[$row.Id] = $true
    }
}
if ($settings.Count -eq 0) { throw 'No overridden GameSettings were found.' }

$core = Remove-GlobalOverrides (Read-Plugin $coreInput) $settings 'Core'
$coreOutput = Join-Path $converted 'StarwindRemasteredV1.15.global-compatible.json'
Write-PluginJson $core $coreOutput
$coreBuild = Join-Path $buildDirectory 'StarwindRemasteredV1.15.esm'
Build-Plugin $coreOutput $coreBuild
$coreBytes = (Get-Item -LiteralPath $coreBuild).Length

$core = $null
[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()

$patch = Remove-GlobalOverrides (Read-Plugin $patchInput) $settings 'Patch'
$masterUpdated = 0
foreach ($master in $patch[0].masters) {
    if ($master[0] -eq 'StarwindRemasteredV1.15.esm') { $master[1] = $coreBytes; $masterUpdated++ }
}
Assert-Equal 'Patch core-master byte count' $masterUpdated 1
$patchOutput = Join-Path $converted 'StarwindRemasteredPatch.global-compatible.json'
Write-PluginJson $patch $patchOutput
$patchBuild = Join-Path $buildDirectory 'StarwindRemasteredPatch.esm'
Build-Plugin $patchOutput $patchBuild

[PSCustomObject]@{
    CorePlugin = $coreBuild
    PatchPlugin = $patchBuild
    RemovedGameSettingIds = $settings.Count
    CoreBytes = $coreBytes
    PatchBytes = (Get-Item -LiteralPath $patchBuild).Length
} | Format-List
