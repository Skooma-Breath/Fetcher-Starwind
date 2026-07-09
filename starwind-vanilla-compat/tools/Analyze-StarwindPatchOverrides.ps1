[CmdletBinding()]
param()

$projectRoot = Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot 'Analyze-StarwindOverrides.ps1') `
    -PluginJson (Join-Path $projectRoot 'converted\StarwindRemasteredPatch.json') `
    -ReportPrefix 'patch-'
if (-not $?) { throw 'Patch override audit failed.' }
