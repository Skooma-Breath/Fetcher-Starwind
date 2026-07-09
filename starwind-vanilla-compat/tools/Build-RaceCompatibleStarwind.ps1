[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$converted = Join-Path $projectRoot 'converted'
$moveRaces = Join-Path $PSScriptRoot 'Move-StarwindRaces.ps1'

$coreJson = Join-Path $converted 'StarwindRemasteredV1.15.json'
$coreOutputJson = Join-Path $converted 'StarwindRemasteredV1.15.vanilla-compatible.json'
& $moveRaces -InputJson $coreJson -OutputJson $coreOutputJson -ExpectedNpcUpdates 519 -OutputPluginName 'StarwindRemasteredV1.15.esm' -BuildPlugin

$coreBuild = Join-Path $projectRoot 'build\Data Files\StarwindRemasteredV1.15.esm'
$coreBytes = (Get-Item -LiteralPath $coreBuild).Length

$patchJson = Join-Path $converted 'StarwindRemasteredPatch.json'
$patchOutputJson = Join-Path $converted 'StarwindRemasteredPatch.vanilla-compatible.json'
& $moveRaces -InputJson $patchJson -OutputJson $patchOutputJson -ExpectedNpcUpdates 718 -UpdatedCoreMasterBytes $coreBytes -OutputPluginName 'StarwindRemasteredPatch.esm' -BuildPlugin

$patchBuild = Join-Path $projectRoot 'build\Data Files\StarwindRemasteredPatch.esm'
$patchBytes = (Get-Item -LiteralPath $patchBuild).Length
[PSCustomObject]@{
    CorePlugin = $coreBuild
    CoreBytes = $coreBytes
    PatchPlugin = $patchBuild
    PatchBytes = $patchBytes
} | Format-List
