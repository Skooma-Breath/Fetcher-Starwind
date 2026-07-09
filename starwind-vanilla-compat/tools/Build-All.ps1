[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

foreach ($script in @(
    'Convert-StarwindSources.ps1',
    'Analyze-StarwindOverrides.ps1',
    'Find-StarwindAssetCollisions.ps1',
    'Compare-StarwindBsaAssets.ps1',
    'Build-CharacterCompatibleStarwind.ps1',
    'Build-BodypartCompatibleStarwind.ps1',
    'Build-NpcCompatibleStarwind.ps1',
    'Build-BookCompatibleStarwind.ps1',
    'Build-GlobalCompatibleStarwind.ps1',
    'Build-AssetCompatibleStarwind.ps1',
    'Build-ScriptGlobalCompatibleStarwind.ps1',
    'Build-BlasterAnimationSources.ps1',
    'Test-Compatibility.ps1'
)) {
    Write-Host "`n==> $script"
    & (Join-Path $root $script)
    if ($LASTEXITCODE -ne 0) { throw "$script failed." }
}
