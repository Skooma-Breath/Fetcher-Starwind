[CmdletBinding()]
param(
    [string]$PluginJson = '',
    [string]$ReportPrefix = ''
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$converted = Join-Path $projectRoot 'converted'
$reportDir = Join-Path $projectRoot 'reports'
if ($PluginJson -eq '') { $PluginJson = Join-Path $converted 'StarwindRemasteredV1.15.json' }
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null

function Get-Records([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "Missing converted plugin: $Path" }
    return @((Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json) | Select-Object -Skip 1)
}

function Get-RecordKey($Record) {
    if ($Record.PSObject.Properties.Name -contains 'id') { return "id:$($Record.id)" }
    switch ($Record.type) {
        'Cell' { return "cell:$($Record.name)|$($Record.data.grid[0])|$($Record.data.grid[1])" }
        'Landscape' { return "land:$($Record.grid[0])|$($Record.grid[1])" }
        'PathGrid' { return "pathgrid:$($Record.cell)|$($Record.data.grid[0])|$($Record.data.grid[1])" }
        default { return $null }
    }
}

$masters = @(
    @{ Name = 'Morrowind.esm'; Path = Join-Path $converted 'Morrowind.json' },
    @{ Name = 'Tribunal.esm'; Path = Join-Path $converted 'Tribunal.json' },
    @{ Name = 'Bloodmoon.esm'; Path = Join-Path $converted 'Bloodmoon.json' }
)

$masterIndex = @{}
foreach ($master in $masters) {
    foreach ($record in Get-Records $master.Path) {
        $key = Get-RecordKey $record
        if ($null -ne $key) { $masterIndex["$($record.type)|$key"] = $master.Name }
    }
}

$overrides = foreach ($record in Get-Records $PluginJson) {
    $key = Get-RecordKey $record
    if ($null -ne $key) {
        $master = $masterIndex["$($record.type)|$key"]
        if ($null -ne $master) {
            [PSCustomObject]@{
                Master = $master
                RecordType = $record.type
                RecordKey = $key
                Id = if ($record.PSObject.Properties.Name -contains 'id') { $record.id } else { '' }
                Name = if ($record.PSObject.Properties.Name -contains 'name') { $record.name } else { '' }
            }
        }
    }
}

$overrides = @($overrides | Sort-Object Master, RecordType, RecordKey)
$overrides | Export-Csv -LiteralPath (Join-Path $reportDir "$($ReportPrefix)overridden-records.csv") -NoTypeInformation -Encoding utf8
$summary = $overrides | Group-Object Master, RecordType | ForEach-Object {
    $parts = $_.Name -split ', '
    [PSCustomObject]@{ Master = $parts[0]; RecordType = $parts[1]; Count = $_.Count }
} | Sort-Object Master, RecordType
$summary | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $reportDir "$($ReportPrefix)override-summary.json") -Encoding utf8
$summary | Format-Table -AutoSize
Write-Output "Total overridden master records: $($overrides.Count)"
