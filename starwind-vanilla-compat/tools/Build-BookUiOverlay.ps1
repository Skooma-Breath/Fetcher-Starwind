[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$umoRoot = Split-Path -Parent $projectRoot
$sourceRoot = if ($env:FETCHER_STARWIND_SOURCE_ROOT) { $env:FETCHER_STARWIND_SOURCE_ROOT } else { $umoRoot }
$steamData = 'C:\Program Files (x86)\Steam\steamapps\common\Morrowind\Data Files'
$starwindData = Join-Path $sourceRoot 'starwind-modded\TotalConversions\Starwindv3AStarWarsConversion\Starwind3.1\Data Files'
$bsatool = 'C:\Program Files\OpenMW 0.50.0\bsatool.exe'
$outputRoot = Join-Path $projectRoot 'build\Starwind Vanilla Compat'
$assetRoot = Join-Path $projectRoot 'assets'
$morrowindBsa = Join-Path $steamData 'Morrowind.bsa'

foreach ($path in @($starwindData, $morrowindBsa, $bsatool, $assetRoot)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required input was not found: $path" }
}

New-Item -ItemType Directory -Force -Path (Join-Path $outputRoot 'Textures\starwind_compat'), (Join-Path $outputRoot 'Sound\Fx\item'), (Join-Path $outputRoot 'Sound\starwind_compat'), (Join-Path $outputRoot 'scripts\starwind-compat') | Out-Null

$bookTexturePaths = @(& $bsatool list $morrowindBsa | Where-Object { $_ -match '^textures\\tx_menubook.*\.dds$' })
if ($bookTexturePaths.Count -eq 0) { throw 'No vanilla Book UI textures were found in Morrowind.bsa.' }
foreach ($relativePath in $bookTexturePaths) {
    & $bsatool extract -f $morrowindBsa $relativePath $outputRoot
    if ($LASTEXITCODE -ne 0) { throw "Failed to extract $relativePath from Morrowind.bsa" }
}

$bookSoundNames = @('bookopen.wav', 'bookclose.wav', 'bookpag1.wav', 'bookpag2.wav')
foreach ($soundName in $bookSoundNames) {
    $officialSound = Join-Path $steamData "Sound\Fx\item\$soundName"
    $starwindSound = Join-Path $starwindData "Sound\Fx\item\$soundName"
    if (-not (Test-Path -LiteralPath $officialSound)) { throw "Official book sound was not found: $officialSound" }
    if (-not (Test-Path -LiteralPath $starwindSound)) { throw "Starwind book sound was not found: $starwindSound" }
    Copy-Item -LiteralPath $officialSound -Destination (Join-Path $outputRoot "Sound\Fx\item\$soundName") -Force
    Copy-Item -LiteralPath $starwindSound -Destination (Join-Path $outputRoot "Sound\starwind_compat\$soundName") -Force
}

$officialMenuClick = Join-Path $steamData 'Sound\Fx\menu click.wav'
$starwindMenuClick = Join-Path $starwindData 'Sound\Fx\menu click.wav'
$overlaidMenuClick = Join-Path $outputRoot 'Sound\Fx\menu click.wav'
if (-not (Test-Path -LiteralPath $officialMenuClick)) { throw ('Official GUI click sound was not found: ' + $officialMenuClick) }
if (-not (Test-Path -LiteralPath $starwindMenuClick)) { throw ('Starwind GUI click override was not found: ' + $starwindMenuClick) }
Copy-Item -LiteralPath $officialMenuClick -Destination $overlaidMenuClick -Force

Copy-Item -LiteralPath (Join-Path $starwindData 'Textures\tx_menubook.dds') -Destination (Join-Path $outputRoot 'Textures\starwind_compat\tablet_reader.dds') -Force
Copy-Item -LiteralPath (Join-Path $assetRoot 'StarwindVanillaCompat.omwscripts') -Destination (Join-Path $outputRoot 'StarwindVanillaCompat.omwscripts') -Force
Copy-Item -LiteralPath (Join-Path $assetRoot 'scripts\starwind-compat\tablet-reader.lua') -Destination (Join-Path $outputRoot 'scripts\starwind-compat\tablet-reader.lua') -Force

$extractedCount = @(Get-ChildItem -LiteralPath (Join-Path $outputRoot 'Textures') -Filter 'tx_menubook*.dds' -File).Count
if ($extractedCount -ne $bookTexturePaths.Count) { throw "Expected $($bookTexturePaths.Count) vanilla Book UI textures, found $extractedCount." }

[PSCustomObject]@{
    Output = $outputRoot
    VanillaBookTextures = $extractedCount
    VanillaBookSounds = $bookSoundNames.Count
    VanillaGuiClickSounds = 1
    TabletTexture = Join-Path $outputRoot 'Textures\starwind_compat\tablet_reader.dds'
    ScriptManifest = Join-Path $outputRoot 'StarwindVanillaCompat.omwscripts'
} | Format-List
