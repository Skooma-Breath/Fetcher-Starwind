[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$umoRoot = Split-Path -Parent $projectRoot
$steamData = 'C:\Program Files (x86)\Steam\steamapps\common\Morrowind\Data Files'
$starwindData = Join-Path $umoRoot 'starwind-modded\TotalConversions\Starwindv3AStarWarsConversion\Starwind3.1\Data Files'
$bsatool = 'C:\Program Files\OpenMW 0.50.0\bsatool.exe'
$outputRoot = Join-Path $projectRoot 'build\Starwind Vanilla Compat'
$assetRoot = Join-Path $projectRoot 'assets'
$morrowindBsa = Join-Path $steamData 'Morrowind.bsa'

foreach ($path in @($starwindData, $morrowindBsa, $bsatool, $assetRoot)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required input was not found: $path" }
}

New-Item -ItemType Directory -Force -Path (Join-Path $outputRoot 'Textures\starwind_compat'), (Join-Path $outputRoot 'scripts\starwind-compat') | Out-Null

$bookTexturePaths = @(& $bsatool list $morrowindBsa | Where-Object { $_ -match '^textures\\tx_menubook.*\.dds$' })
if ($bookTexturePaths.Count -eq 0) { throw 'No vanilla Book UI textures were found in Morrowind.bsa.' }
foreach ($relativePath in $bookTexturePaths) {
    & $bsatool extract -f $morrowindBsa $relativePath $outputRoot
    if ($LASTEXITCODE -ne 0) { throw "Failed to extract $relativePath from Morrowind.bsa" }
}

Copy-Item -LiteralPath (Join-Path $starwindData 'Textures\tx_menubook.dds') -Destination (Join-Path $outputRoot 'Textures\starwind_compat\tablet_reader.dds') -Force
Copy-Item -LiteralPath (Join-Path $assetRoot 'StarwindVanillaCompat.omwscripts') -Destination (Join-Path $outputRoot 'StarwindVanillaCompat.omwscripts') -Force
Copy-Item -LiteralPath (Join-Path $assetRoot 'scripts\starwind-compat\tablet-reader.lua') -Destination (Join-Path $outputRoot 'scripts\starwind-compat\tablet-reader.lua') -Force

$extractedCount = @(Get-ChildItem -LiteralPath (Join-Path $outputRoot 'Textures') -Filter 'tx_menubook*.dds' -File).Count
if ($extractedCount -ne $bookTexturePaths.Count) { throw "Expected $($bookTexturePaths.Count) vanilla Book UI textures, found $extractedCount." }

[PSCustomObject]@{
    Output = $outputRoot
    VanillaBookTextures = $extractedCount
    TabletTexture = Join-Path $outputRoot 'Textures\starwind_compat\tablet_reader.dds'
    ScriptManifest = Join-Path $outputRoot 'StarwindVanillaCompat.omwscripts'
} | Format-List
