[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

foreach ($script in @(
    'Convert-StarwindSources.ps1',
    'Analyze-StarwindOverrides.ps1',
    'Analyze-StarwindPatchOverrides.ps1',
    'Find-StarwindAssetCollisions.ps1',
    'Compare-StarwindBsaAssets.ps1',
    'Build-CharacterCompatibleStarwind.ps1',
    'Build-BodypartCompatibleStarwind.ps1',
    'Build-NpcCompatibleStarwind.ps1',
    'Build-BookCompatibleStarwind.ps1',
    'Build-GlobalCompatibleStarwind.ps1',
    'Build-AssetCompatibleStarwind.ps1',
    'Build-ScriptGlobalCompatibleStarwind.ps1',
    'Build-WorldCompatibleStarwind.ps1',
    'Build-DialogueCompatibleStarwind.ps1',
    'Build-RecordCompatibleStarwind.ps1',
    'Build-BlasterAnimationSources.ps1',
    'Build-MorrowindLocalAssetManifest.ps1',
    'Test-Compatibility.ps1'
)) {
    Write-Host "`n==> $script"
    $scriptPath = Join-Path $root $script
    $process = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$scriptPath`"") `
        -NoNewWindow -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "$script failed with exit code $($process.ExitCode)." }
}
