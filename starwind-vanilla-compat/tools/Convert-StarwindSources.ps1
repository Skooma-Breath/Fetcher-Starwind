[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$umoRoot = Split-Path -Parent $projectRoot
$sourceRoot = if ($env:FETCHER_STARWIND_SOURCE_ROOT) { $env:FETCHER_STARWIND_SOURCE_ROOT } else { $umoRoot }
$tes3conv = Join-Path $sourceRoot 'starwind-modded\tes3conv.exe'
$starwindData = Join-Path $sourceRoot 'starwind-modded\TotalConversions\Starwindv3AStarWarsConversion\Starwind3.1\Data Files'
$officialData = 'C:\Program Files (x86)\Steam\steamapps\common\Morrowind\Data Files'
$output = Join-Path $projectRoot 'converted'

if (-not (Test-Path -LiteralPath $tes3conv)) { throw "tes3conv was not found at $tes3conv" }
if (-not (Test-Path -LiteralPath $officialData)) { throw "Official data files were not found at $officialData" }

New-Item -ItemType Directory -Force -Path $output | Out-Null

$sources = @(
    @{ Input = Join-Path $starwindData 'StarwindRemasteredV1.15.esm'; Output = Join-Path $output 'StarwindRemasteredV1.15.json' },
    @{ Input = Join-Path $starwindData 'StarwindRemasteredPatch.esm'; Output = Join-Path $output 'StarwindRemasteredPatch.json' },
    @{ Input = Join-Path $officialData 'Morrowind.esm'; Output = Join-Path $output 'Morrowind.json' },
    @{ Input = Join-Path $officialData 'Tribunal.esm'; Output = Join-Path $output 'Tribunal.json' },
    @{ Input = Join-Path $officialData 'Bloodmoon.esm'; Output = Join-Path $output 'Bloodmoon.json' }
)

foreach ($source in $sources) {
    if ($Force -or -not (Test-Path -LiteralPath $source.Output)) {
        & $tes3conv $source.Input $source.Output
        if ($LASTEXITCODE -ne 0) { throw "tes3conv failed for $($source.Input)" }
    }
}
