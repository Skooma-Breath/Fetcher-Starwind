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

function Replace-Identifiers([string]$text, $map, [ref]$count) {
    $result = $text
    foreach ($oldId in $map.Keys) {
        $pattern = '(?i)(?<![A-Za-z0-9_])' + [regex]::Escape($oldId) + '(?![A-Za-z0-9_])'
        $matches = [regex]::Matches($result, $pattern).Count
        if ($matches -gt 0) {
            $result = [regex]::Replace($result, $pattern, [string]$map[$oldId])
            $count.Value += $matches
        }
    }
    return $result
}

function Update-ScriptLinks($records, $scriptMap, [string]$label) {
    $renamedScripts = 0
    $linkedRecords = 0
    $sourceChanges = 0
    foreach ($record in $records) {
        if ($record.type -eq 'Script' -and $scriptMap.Contains($record.id)) {
            $record.id = $scriptMap[$record.id]
            $renamedScripts++
        }
        if ($record.PSObject.Properties['script'] -and $scriptMap.Contains($record.script)) {
            $record.script = $scriptMap[$record.script]
            $linkedRecords++
        }
        if ($record.type -eq 'Script' -and $record.PSObject.Properties['text']) {
            $record.text = Replace-Identifiers $record.text $scriptMap ([ref]$sourceChanges)
        }
        if ($record.type -eq 'DialogueInfo' -and $record.PSObject.Properties['result']) {
            $record.result = Replace-Identifiers $record.result $scriptMap ([ref]$sourceChanges)
        }
    }
    $remaining = @($records | Where-Object { $_.type -eq 'Script' -and $scriptMap.Contains($_.id) }).Count
    if ($remaining -ne 0) { throw "$label still contains overwritten Script IDs." }
    Write-Output "$label script migration: renamed=$renamedScripts, linked-records=$linkedRecords, source-token-updates=$sourceChanges"
}

function Remove-GlobalRecords($plugin, $globalIds, $startIds, [string]$label) {
    $records = @($plugin | Select-Object -Skip 1)
    $globalRecords = @($records | Where-Object { $_.type -eq 'GlobalVariable' -and $globalIds.Contains($_.id) })
    $startRecords = @($records | Where-Object { $_.type -eq 'StartScript' -and $startIds.Contains($_.id) })
    foreach ($id in $globalIds.Keys) {
        $references = 0
        foreach ($record in $records | Where-Object { $_.type -eq 'Script' -or $_.type -eq 'DialogueInfo' }) {
            $property = if ($record.type -eq 'Script') { $record.PSObject.Properties['text'] } else { $record.PSObject.Properties['result'] }
            if ($property) {
                # Ignore source-code comments and message strings. They can mention a
                # global by name without referring to the variable at runtime.
                $code = [regex]::Replace([string]$property.Value, '(?m);.*$', '')
                $code = [regex]::Replace($code, '"(?:""|[^"])*"', '""')
                $references += [regex]::Matches($code, '(?i)(?<![A-Za-z0-9_])' + [regex]::Escape($id) + '(?![A-Za-z0-9_])').Count
            }
        }
        if ($references -ne 0) { throw "$label global $id is referenced $references times and cannot be safely removed." }
    }
    $kept = @($plugin[0]) + @($records | Where-Object {
        -not (($_.type -eq 'GlobalVariable' -and $globalIds.Contains($_.id)) -or ($_.type -eq 'StartScript' -and $startIds.Contains($_.id)))
    })
    $kept[0].num_objects = $kept.Count - 1
    Write-Host "$label removed global variables=$($globalRecords.Count), deleted foreign start-script records=$($startRecords.Count)"
    return ,$kept
}

if (-not (Test-Path -LiteralPath $tes3conv)) { throw "tes3conv was not found at $tes3conv" }
$coreInput = Join-Path $converted 'StarwindRemasteredV1.15.asset-compatible.json'
$patchInput = Join-Path $converted 'StarwindRemasteredPatch.asset-compatible.json'
if (-not (Test-Path -LiteralPath $coreInput) -or -not (Test-Path -LiteralPath $patchInput)) {
    throw 'Run Build-AssetCompatibleStarwind.ps1 before this script/global build.'
}

$scriptMap = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
$globalIds = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
$startIds = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($reportName in @('overridden-records.csv', 'patch-overridden-records.csv')) {
    foreach ($row in Import-Csv -LiteralPath (Join-Path $projectRoot "reports\$reportName")) {
        if ($row.RecordType -eq 'Script') {
            $newId = "SW_$($row.Id)"
            if ($newId.Length -gt 32) { throw "Renamed Script ID exceeds TES3's 32-character limit: $newId" }
            $scriptMap[$row.Id] = $newId
        } elseif ($row.RecordType -eq 'GlobalVariable') {
            $globalIds[$row.Id] = $true
        } elseif ($row.RecordType -eq 'StartScript') {
            $startIds[$row.Id] = $true
        }
    }
}
if ($scriptMap.Count -eq 0 -or $globalIds.Count -eq 0 -or $startIds.Count -eq 0) { throw 'Expected Script, GlobalVariable, and StartScript collisions were not found.' }

$core = Remove-GlobalRecords (Read-Plugin $coreInput) $globalIds $startIds 'Core'
Update-ScriptLinks @($core | Select-Object -Skip 1) $scriptMap 'Core'
$coreOutput = Join-Path $converted 'StarwindRemasteredV1.15.script-global-compatible.json'
Write-PluginJson $core $coreOutput
$coreBuild = Join-Path $buildDirectory 'StarwindRemasteredV1.15.esm'
Build-Plugin $coreOutput $coreBuild
$coreBytes = (Get-Item -LiteralPath $coreBuild).Length

$core = $null
[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()

$patch = Remove-GlobalRecords (Read-Plugin $patchInput) $globalIds $startIds 'Patch'
Update-ScriptLinks @($patch | Select-Object -Skip 1) $scriptMap 'Patch'
$masterUpdated = 0
foreach ($master in $patch[0].masters) {
    if ($master[0] -eq 'StarwindRemasteredV1.15.esm') { $master[1] = $coreBytes; $masterUpdated++ }
}
if ($masterUpdated -ne 1) { throw "Expected one core master byte-count update; made $masterUpdated." }
$patchOutput = Join-Path $converted 'StarwindRemasteredPatch.script-global-compatible.json'
Write-PluginJson $patch $patchOutput
$patchBuild = Join-Path $buildDirectory 'StarwindRemasteredPatch.esm'
Build-Plugin $patchOutput $patchBuild

[PSCustomObject]@{
    CorePlugin = $coreBuild
    PatchPlugin = $patchBuild
    IsolatedScripts = $scriptMap.Count
    RemovedGlobalVariables = $globalIds.Count
    RemovedForeignStartScripts = $startIds.Count
    CoreBytes = $coreBytes
    PatchBytes = (Get-Item -LiteralPath $patchBuild).Length
} | Format-List
