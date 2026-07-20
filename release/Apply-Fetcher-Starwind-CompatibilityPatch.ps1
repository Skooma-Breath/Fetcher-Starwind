[CmdletBinding()]
param(
    [string] $InstallRoot = "",
    [Parameter(Mandatory = $true)][string] $StarwindDataRoot
)

$ErrorActionPreference = "Stop"

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string] $Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-FullPath {
    param([Parameter(Mandatory = $true)][string] $Path)
    return [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

function Assert-PathInside {
    param(
        [Parameter(Mandatory = $true)][string] $Parent,
        [Parameter(Mandatory = $true)][string] $Child,
        [Parameter(Mandatory = $true)][string] $Description
    )
    $parentPath = (Get-FullPath $Parent) + [IO.Path]::DirectorySeparatorChar
    $childPath = Get-FullPath $Child
    if (-not $childPath.StartsWith($parentPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description is outside the expected root: $childPath"
    }
}

function Get-OpenMwDataPaths {
    param([Parameter(Mandatory = $true)][string] $Root)

    $configPath = Join-Path $Root "openmw.cfg"
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "OpenMW configuration was not found: $configPath"
    }
    $paths = New-Object System.Collections.Generic.List[string]
    $seen = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
    foreach ($line in Get-Content -LiteralPath $configPath) {
        if ($line -notmatch '^\s*data\s*=\s*(.+?)\s*$') {
            continue
        }
        $value = $Matches[1].Trim()
        if ($value.Length -ge 2 -and $value[0] -eq '"' -and $value[$value.Length - 1] -eq '"') {
            $value = $value.Substring(1, $value.Length - 2)
        }
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }
        $candidate = if ([IO.Path]::IsPathRooted($value)) {
            $value
        }
        else {
            Join-Path $Root $value
        }
        try {
            $fullPath = Get-FullPath $candidate
        }
        catch {
            continue
        }
        if ((Test-Path -LiteralPath $fullPath -PathType Container) -and $seen.Add($fullPath)) {
            $paths.Add($fullPath)
        }
    }
    return @($paths)
}

function Get-MorrowindDataRoots {
    param([Parameter(Mandatory = $true)][string] $Root)

    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($path in Get-OpenMwDataPaths -Root $Root) {
        $candidates.Add($path)
    }
    foreach ($commonPath in @(
        'C:\Program Files (x86)\Steam\steamapps\common\Morrowind\Data Files',
        'C:\GOG Games\Morrowind\Data Files'
    )) {
        if (Test-Path -LiteralPath $commonPath -PathType Container) {
            $candidates.Add((Get-FullPath $commonPath))
        }
    }

    $roots = New-Object System.Collections.Generic.List[string]
    $seen = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in $candidates) {
        if ((Test-Path -LiteralPath (Join-Path $candidate 'Morrowind.esm') -PathType Leaf) -and
            $seen.Add($candidate)) {
            $roots.Add($candidate)
        }
    }
    if ($roots.Count -eq 0) {
        throw 'Could not locate a configured Morrowind Data Files directory containing Morrowind.esm.'
    }
    return @($roots)
}

function Get-BsaToolPath {
    param([Parameter(Mandatory = $true)][string] $Root)

    $bundled = Join-Path $Root 'bsatool.exe'
    if (Test-Path -LiteralPath $bundled -PathType Leaf) {
        return $bundled
    }
    $command = Get-Command bsatool.exe -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }
    throw "bsatool.exe was not found in the Fetcher installation or PATH."
}

function Find-ByteSequence {
    param(
        [Parameter(Mandatory = $true)][byte[]] $Data,
        [Parameter(Mandatory = $true)][byte[]] $Pattern,
        [int] $StartIndex = 0
    )

    if ($Pattern.Length -eq 0) {
        return $StartIndex
    }
    $lastStart = $Data.Length - $Pattern.Length
    for ($index = $StartIndex; $index -le $lastStart; ++$index) {
        if ($Data[$index] -ne $Pattern[0]) {
            continue
        }
        $matched = $true
        for ($offset = 1; $offset -lt $Pattern.Length; ++$offset) {
            if ($Data[$index + $offset] -ne $Pattern[$offset]) {
                $matched = $false
                break
            }
        }
        if ($matched) {
            return $index
        }
    }
    return -1
}

function Replace-LengthPrefixedAsciiString {
    param(
        [Parameter(Mandatory = $true)][byte[]] $Data,
        [Parameter(Mandatory = $true)][string] $OldValue,
        [Parameter(Mandatory = $true)][string] $NewValue,
        [Parameter(Mandatory = $true)][int] $ExpectedOccurrences
    )

    $encoding = [Text.Encoding]::ASCII
    $oldBytes = $encoding.GetBytes($OldValue)
    $newBytes = $encoding.GetBytes($NewValue)
    if ($encoding.GetString($oldBytes) -ne $OldValue -or $encoding.GetString($newBytes) -ne $NewValue) {
        throw 'NIF texture paths must contain only ASCII characters.'
    }
    $pattern = [byte[]]::new(4 + $oldBytes.Length)
    [BitConverter]::GetBytes([uint32]$oldBytes.Length).CopyTo($pattern, 0)
    $oldBytes.CopyTo($pattern, 4)
    $replacement = [byte[]]::new(4 + $newBytes.Length)
    [BitConverter]::GetBytes([uint32]$newBytes.Length).CopyTo($replacement, 0)
    $newBytes.CopyTo($replacement, 4)

    $positions = New-Object System.Collections.Generic.List[int]
    $searchAt = 0
    while ($searchAt -le $Data.Length - $pattern.Length) {
        $foundAt = Find-ByteSequence -Data $Data -Pattern $pattern -StartIndex $searchAt
        if ($foundAt -lt 0) {
            break
        }
        $positions.Add($foundAt)
        $searchAt = $foundAt + $pattern.Length
    }
    if ($positions.Count -ne $ExpectedOccurrences) {
        throw "Expected $ExpectedOccurrences occurrence(s) of NIF texture path '$OldValue', found $($positions.Count)."
    }

    $output = [IO.MemoryStream]::new()
    try {
        $sourceOffset = 0
        foreach ($position in $positions) {
            $output.Write($Data, $sourceOffset, $position - $sourceOffset)
            $output.Write($replacement, 0, $replacement.Length)
            $sourceOffset = $position + $pattern.Length
        }
        $output.Write($Data, $sourceOffset, $Data.Length - $sourceOffset)
        return $output.ToArray()
    }
    finally {
        $output.Dispose()
    }
}

function Resolve-MorrowindAssetSource {
    param(
        [Parameter(Mandatory = $true)] $Source,
        [Parameter(Mandatory = $true)][string[]] $DataRoots,
        [Parameter(Mandatory = $true)][string] $BsaTool,
        [Parameter(Mandatory = $true)][string] $WorkRoot
    )

    $relativePath = ([string]$Source.path).Replace('/', '\')
    $expectedHash = ([string]$Source.sha256).ToLowerInvariant()
    foreach ($dataRoot in $DataRoots) {
        $loosePath = Join-Path $dataRoot $relativePath
        if ((Test-Path -LiteralPath $loosePath -PathType Leaf) -and (Get-Sha256 $loosePath) -eq $expectedHash) {
            return $loosePath
        }
    }

    $archiveName = [string]$Source.archive
    $archiveRelativePath = [string]$Source.archivePath
    if (-not [string]::IsNullOrWhiteSpace($archiveName) -and
        -not [string]::IsNullOrWhiteSpace($archiveRelativePath)) {
        foreach ($dataRoot in $DataRoots) {
            $archivePath = Join-Path $dataRoot $archiveName
            if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
                continue
            }
            $extractRoot = Join-Path $WorkRoot ([IO.Path]::GetFileNameWithoutExtension($archiveName))
            $extractedPath = Join-Path $extractRoot $archiveRelativePath.Replace('/', '\')
            if (-not (Test-Path -LiteralPath $extractedPath -PathType Leaf)) {
                New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null
                $archiveEntryPath = $archiveRelativePath.Replace('/', '\')
                & $BsaTool extract -f $archivePath $archiveEntryPath $extractRoot | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "Could not extract $archiveRelativePath from $archivePath"
                }
            }
            if ((Test-Path -LiteralPath $extractedPath -PathType Leaf) -and
                (Get-Sha256 $extractedPath) -eq $expectedHash) {
                return $extractedPath
            }
        }
    }
    throw "The tester's Morrowind installation does not contain the expected official asset: $($Source.path)"
}

function Install-LocalMorrowindAssets {
    param(
        [Parameter(Mandatory = $true)] $LocalManifest,
        [Parameter(Mandatory = $true)][string[]] $DataRoots,
        [Parameter(Mandatory = $true)][string] $BsaTool,
        [Parameter(Mandatory = $true)][string] $OverlayRoot,
        [Parameter(Mandatory = $true)][string] $WorkRoot
    )

    $installed = 0
    foreach ($file in @($LocalManifest.files)) {
        $relativeDestination = ([string]$file.destinationPath).Replace('/', '\')
        if ([string]::IsNullOrWhiteSpace($relativeDestination) -or [IO.Path]::IsPathRooted($relativeDestination) -or
            @($relativeDestination.Split('\')) -contains '..') {
            throw "Unsafe local Morrowind asset destination: $($file.destinationPath)"
        }
        $destination = Get-FullPath (Join-Path $OverlayRoot $relativeDestination)
        Assert-PathInside -Parent $OverlayRoot -Child $destination -Description 'Local Morrowind asset destination'
        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            throw "The release payload unexpectedly contains an official Morrowind-derived file: $($file.destinationPath)"
        }
        $source = Resolve-MorrowindAssetSource -Source $file.source -DataRoots $DataRoots -BsaTool $BsaTool -WorkRoot $WorkRoot
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null

        switch ([string]$file.operation) {
            'copy' {
                Copy-Item -LiteralPath $source -Destination $destination -Force
            }
            'rewriteNifTexturePaths' {
                [byte[]]$bytes = [IO.File]::ReadAllBytes($source)
                foreach ($replacement in @($file.replacements)) {
                    $bytes = Replace-LengthPrefixedAsciiString -Data $bytes `
                        -OldValue ([string]$replacement.from) `
                        -NewValue ([string]$replacement.to) `
                        -ExpectedOccurrences ([int]$replacement.occurrences)
                }
                [IO.File]::WriteAllBytes($destination, $bytes)
            }
            default {
                throw "Unsupported local Morrowind asset operation: $($file.operation)"
            }
        }
        if ((Get-Sha256 $destination) -ne ([string]$file.resultSha256).ToLowerInvariant()) {
            throw "Locally reconstructed Morrowind asset checksum mismatch: $($file.destinationPath)"
        }
        ++$installed
    }
    return $installed
}

$sourcePath = Get-FullPath $StarwindDataRoot
if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
    throw "Starwind data root does not exist: $sourcePath"
}
if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $candidate = $sourcePath
    while ($true) {
        if ((Test-Path -LiteralPath (Join-Path $candidate "openmw.cfg") -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $candidate "openmw.exe") -PathType Leaf)) {
            $InstallRoot = $candidate
            break
        }
        $parent = Split-Path -Parent $candidate
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $candidate) {
            throw "Could not infer the Fetcher installation root from: $sourcePath"
        }
        $candidate = $parent
    }
}
$installPath = Get-FullPath $InstallRoot
if (-not (Test-Path -LiteralPath $installPath -PathType Container)) {
    throw "Install root does not exist: $installPath"
}
Assert-PathInside -Parent $installPath -Child $sourcePath -Description "Starwind data root"

foreach ($requiredPath in @("StarwindRemasteredV1.15.esm", "StarwindRemasteredPatch.esm", "Meshes")) {
    if (-not (Test-Path -LiteralPath (Join-Path $sourcePath $requiredPath))) {
        throw "The selected Starwind data root is missing $requiredPath`: $sourcePath"
    }
}

$packageRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$manifestPath = Join-Path $packageRoot "fetcher-starwind-compat-patch.json"
$payloadRoot = Join-Path $packageRoot "payload"
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Patch manifest is missing: $manifestPath"
}
if (-not (Test-Path -LiteralPath $payloadRoot -PathType Container)) {
    throw "Patch payload is missing: $payloadRoot"
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ([int]$manifest.schemaVersion -ne 1 -or [string]$manifest.patchId -ne "fetcher-starwind-compat") {
    throw "The Starwind compatibility patch manifest is unsupported."
}
$localAssetManifestName = [string]$manifest.localAssetManifest
if ([string]::IsNullOrWhiteSpace($localAssetManifestName) -or
    [IO.Path]::IsPathRooted($localAssetManifestName) -or
    $localAssetManifestName -ne [IO.Path]::GetFileName($localAssetManifestName)) {
    throw "The Starwind compatibility patch does not name a safe local Morrowind asset manifest."
}
$localAssetManifestPath = Join-Path $packageRoot $localAssetManifestName
if (-not (Test-Path -LiteralPath $localAssetManifestPath -PathType Leaf)) {
    throw "Local Morrowind asset manifest is missing: $localAssetManifestPath"
}
if ((Get-Sha256 $localAssetManifestPath) -ne ([string]$manifest.localAssetManifestSha256).ToLowerInvariant()) {
    throw "Local Morrowind asset manifest checksum verification failed."
}
$localAssetManifest = Get-Content -LiteralPath $localAssetManifestPath -Raw | ConvertFrom-Json
if ([int]$localAssetManifest.schemaVersion -ne 1 -or
    [string]$localAssetManifest.manifestId -ne "fetcher-starwind-local-morrowind-assets") {
    throw "The local Morrowind asset manifest is unsupported."
}
if (@($localAssetManifest.files).Count -ne [int]$manifest.localAssetFileCount) {
    throw "The local Morrowind asset file count does not match the patch manifest."
}
$localDestinations = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
foreach ($localFile in @($localAssetManifest.files)) {
    $destinationPath = ([string]$localFile.destinationPath).Replace("\", "/")
    $sourceRelativePath = ([string]$localFile.source.path).Replace("\", "/")
    $archiveRelativePath = ([string]$localFile.source.archivePath).Replace("\", "/")
    foreach ($candidatePath in @($destinationPath, $sourceRelativePath, $archiveRelativePath)) {
        if ([string]::IsNullOrWhiteSpace($candidatePath)) {
            continue
        }
        $platformPath = $candidatePath.Replace('/', '\')
        if ([IO.Path]::IsPathRooted($platformPath) -or @($platformPath.Split('\')) -contains '..') {
            throw "Unsafe path in local Morrowind asset recipe: $candidatePath"
        }
    }
    if ([string]::IsNullOrWhiteSpace($destinationPath) -or [string]::IsNullOrWhiteSpace($sourceRelativePath)) {
        throw "Incomplete local Morrowind asset recipe."
    }
    if (-not $localDestinations.Add($destinationPath)) {
        throw "Duplicate local Morrowind asset destination: $destinationPath"
    }
    if ([string]$localFile.operation -notin @('copy', 'rewriteNifTexturePaths')) {
        throw "Unsupported local Morrowind asset operation: $($localFile.operation)"
    }
    if (([string]$localFile.source.sha256) -notmatch '^[0-9a-fA-F]{64}$' -or
        ([string]$localFile.resultSha256) -notmatch '^[0-9a-fA-F]{64}$') {
        throw "Invalid local Morrowind asset hashes: $destinationPath"
    }
}
$manifestFiles = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
foreach ($file in @($manifest.files)) {
    $relativePath = ([string]$file.path).Replace("/", [IO.Path]::DirectorySeparatorChar)
    if ([string]::IsNullOrWhiteSpace($relativePath) -or [IO.Path]::IsPathRooted($relativePath) -or
        @($relativePath.Split([IO.Path]::DirectorySeparatorChar)) -contains "..") {
        throw "Unsafe payload path in manifest: $($file.path)"
    }
    $payloadPath = Get-FullPath (Join-Path $payloadRoot $relativePath)
    if (-not $manifestFiles.Add(([string]$file.path).Replace("\", "/"))) {
        throw "Duplicate payload path in manifest: $($file.path)"
    }
    Assert-PathInside -Parent $payloadRoot -Child $payloadPath -Description "Payload file"
    if (-not (Test-Path -LiteralPath $payloadPath -PathType Leaf)) {
        throw "Payload file is missing: $($file.path)"
    }
    $payloadFile = Get-Item -LiteralPath $payloadPath
    if ([int64]$payloadFile.Length -ne [int64]$file.size -or (Get-Sha256 $payloadPath) -ne ([string]$file.sha256).ToLowerInvariant()) {
        throw "Payload verification failed: $($file.path)"
    }
}
$actualPayloadFiles = @(Get-ChildItem -LiteralPath $payloadRoot -Recurse -File)
if ($actualPayloadFiles.Count -ne $manifestFiles.Count) {
    throw "The payload contains files that are absent from its manifest."
}
foreach ($payloadFile in $actualPayloadFiles) {
    $relativePath = $payloadFile.FullName.Substring($payloadRoot.Length + 1).Replace("\", "/")
    if (-not $manifestFiles.Contains($relativePath)) {
        throw "Unmanifested payload file: $relativePath"
    }
}

$dataFilesRoot = Join-Path $installPath "Data Files"
New-Item -ItemType Directory -Force -Path $dataFilesRoot | Out-Null
$targetPath = Join-Path $dataFilesRoot "fetcher-starwind-compat"
Assert-PathInside -Parent $dataFilesRoot -Child $targetPath -Description "Managed patch directory"
$transactionId = [Guid]::NewGuid().ToString("N")
$stagePath = Join-Path $dataFilesRoot (".fetcher-starwind-compat-stage-{0}" -f $transactionId)
$backupPath = Join-Path $dataFilesRoot (".fetcher-starwind-compat-backup-{0}" -f $transactionId)

$starwindMusicPath = Join-Path $sourcePath "Music"
$musicQuarantinePath = Join-Path $installPath "_fetcher_update\quarantine\starwind-music\Music"
Assert-PathInside -Parent $installPath -Child $starwindMusicPath -Description "Starwind source music directory"
Assert-PathInside -Parent $installPath -Child $musicQuarantinePath -Description "Starwind music quarantine directory"

if (Test-Path -LiteralPath $starwindMusicPath -PathType Container) {
    $musicImportPath = $starwindMusicPath
}
elseif (Test-Path -LiteralPath $musicQuarantinePath -PathType Container) {
    $musicImportPath = $musicQuarantinePath
}
else {
    throw "Could not find Starwind's Music directory in its data root or Fetcher quarantine."
}
foreach ($musicCategory in @("Battle", "Explore", "Special")) {
    if (-not (Test-Path -LiteralPath (Join-Path $musicImportPath $musicCategory) -PathType Container)) {
        throw "Starwind's soundtrack is missing its $musicCategory directory: $musicImportPath"
    }
}
$starwindMusicFiles = @(Get-ChildItem -LiteralPath $musicImportPath -Recurse -File | Where-Object {
    $_.Extension -match '^(?i:\.flac|\.mp3|\.ogg|\.wav)$'
})
if ($starwindMusicFiles.Count -eq 0) {
    throw "Starwind's soundtrack contains no supported audio files: $musicImportPath"
}

$morrowindDataRoots = @(Get-MorrowindDataRoots -Root $installPath)
$bsatoolPath = Get-BsaToolPath -Root $installPath
$localAssetWorkRoot = Join-Path $installPath ("_fetcher_update\work\starwind-morrowind-assets-{0}" -f $transactionId)
Assert-PathInside -Parent $installPath -Child $localAssetWorkRoot -Description "Local Morrowind asset work directory"

try {
    New-Item -ItemType Directory -Path $stagePath | Out-Null
    Copy-Item -LiteralPath (Join-Path $payloadRoot "Data Files") -Destination $stagePath -Recurse
    Copy-Item -LiteralPath (Join-Path $payloadRoot "Starwind Vanilla Compat") -Destination $stagePath -Recurse
    Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $stagePath "fetcher-starwind-compat-patch.json")
    Copy-Item -LiteralPath $localAssetManifestPath -Destination (Join-Path $stagePath $localAssetManifestName)

    $stageOverlayPath = Join-Path $stagePath "Starwind Vanilla Compat"
    $localAssetCount = Install-LocalMorrowindAssets `
        -LocalManifest $localAssetManifest `
        -DataRoots $morrowindDataRoots `
        -BsaTool $bsatoolPath `
        -OverlayRoot $stageOverlayPath `
        -WorkRoot $localAssetWorkRoot
    if ($localAssetCount -ne [int]$manifest.localAssetFileCount) {
        throw "Expected to reconstruct $($manifest.localAssetFileCount) local Morrowind assets, created $localAssetCount."
    }
    Write-Host "Reconstructed $localAssetCount compatibility file(s) from the tester's Morrowind installation."

    $managedMusicPath = Join-Path $stagePath "Starwind Vanilla Compat\Music\Starwind"
    New-Item -ItemType Directory -Force -Path $managedMusicPath | Out-Null
    foreach ($musicItem in Get-ChildItem -LiteralPath $musicImportPath -Force) {
        Copy-Item -LiteralPath $musicItem.FullName -Destination $managedMusicPath -Recurse -Force
    }
    foreach ($musicFile in $starwindMusicFiles) {
        $relativeMusicPath = $musicFile.FullName.Substring($musicImportPath.Length + 1)
        $managedMusicFile = Join-Path $managedMusicPath $relativeMusicPath
        if (-not (Test-Path -LiteralPath $managedMusicFile -PathType Leaf) -or
            $musicFile.Length -ne (Get-Item -LiteralPath $managedMusicFile).Length -or
            (Get-Sha256 $musicFile.FullName) -ne (Get-Sha256 $managedMusicFile)) {
            throw "Managed Starwind soundtrack verification failed: $relativeMusicPath"
        }
    }

    if (Test-Path -LiteralPath $targetPath) {
        Move-Item -LiteralPath $targetPath -Destination $backupPath
    }
    try {
        Move-Item -LiteralPath $stagePath -Destination $targetPath
    }
    catch {
        if (Test-Path -LiteralPath $backupPath) {
            Move-Item -LiteralPath $backupPath -Destination $targetPath
        }
        throw
    }
    if (Test-Path -LiteralPath $backupPath) {
        Remove-Item -LiteralPath $backupPath -Recurse -Force
    }
}
finally {
    if (Test-Path -LiteralPath $stagePath) {
        Remove-Item -LiteralPath $stagePath -Recurse -Force
    }
    if (Test-Path -LiteralPath $localAssetWorkRoot) {
        Remove-Item -LiteralPath $localAssetWorkRoot -Recurse -Force
    }
}

Write-Host "Installed Starwind compatibility patch $($manifest.patchVersion):"
Write-Host "  $targetPath"

if (Test-Path -LiteralPath $starwindMusicPath -PathType Container) {
    $musicQuarantineParent = Split-Path -Parent $musicQuarantinePath
    New-Item -ItemType Directory -Force -Path $musicQuarantineParent | Out-Null
    $musicQuarantineBackup = Join-Path $musicQuarantineParent ("Music-backup-{0}" -f [Guid]::NewGuid().ToString("N"))
    Assert-PathInside -Parent $installPath -Child $musicQuarantineBackup -Description "Starwind music quarantine backup"
    if (Test-Path -LiteralPath $musicQuarantinePath) {
        Move-Item -LiteralPath $musicQuarantinePath -Destination $musicQuarantineBackup
    }
    try {
        Move-Item -LiteralPath $starwindMusicPath -Destination $musicQuarantinePath
    }
    catch {
        if (Test-Path -LiteralPath $musicQuarantineBackup) {
            Move-Item -LiteralPath $musicQuarantineBackup -Destination $musicQuarantinePath
        }
        throw
    }
    if (Test-Path -LiteralPath $musicQuarantineBackup) {
        Remove-Item -LiteralPath $musicQuarantineBackup -Recurse -Force
    }
}
Write-Host "Relocated $($starwindMusicFiles.Count) Starwind soundtrack file(s) to the managed Music/Starwind namespace."

$starwindTexturesPath = Join-Path $sourcePath "Textures"
$uiQuarantinePath = Join-Path $installPath "_fetcher_update\quarantine\starwind-ui\Textures"
Assert-PathInside -Parent $installPath -Child $uiQuarantinePath -Description "Starwind UI quarantine directory"
$quarantinedUiFiles = 0
if (Test-Path -LiteralPath $starwindTexturesPath -PathType Container) {
    New-Item -ItemType Directory -Force -Path $uiQuarantinePath | Out-Null
    $datapadTexturePath = Join-Path $starwindTexturesPath "JMenuScreen.dds"
    $quarantinedDatapadTexturePath = Join-Path $uiQuarantinePath "JMenuScreen.dds"
    if (Test-Path -LiteralPath $quarantinedDatapadTexturePath -PathType Leaf) {
        if (-not (Test-Path -LiteralPath $datapadTexturePath -PathType Leaf)) {
            Move-Item -LiteralPath $quarantinedDatapadTexturePath -Destination $datapadTexturePath -Force
            Write-Host "Restored Starwind datapad screen texture: JMenuScreen.dds"
        }
        else {
            Remove-Item -LiteralPath $quarantinedDatapadTexturePath -Force
        }
    }
    foreach ($uiTexture in Get-ChildItem -LiteralPath $starwindTexturesPath -File | Where-Object {
        $_.Name -match '^(?i:menu_|tx_menu|scroll|cursor).*\.dds$'
    }) {
        Move-Item -LiteralPath $uiTexture.FullName -Destination (Join-Path $uiQuarantinePath $uiTexture.Name) -Force
        ++$quarantinedUiFiles
    }
}
Write-Host "Quarantined $quarantinedUiFiles Starwind root UI texture override(s)."

$configScript = Join-Path $installPath "Apply-Fetcher-Public-Test-Config.ps1"
if (-not (Test-Path -LiteralPath $configScript -PathType Leaf)) {
    throw "Fetcher public test configuration script is missing: $configScript"
}
Write-Host "Regenerating openmw.cfg after the Starwind compatibility patch..."
& $configScript
if (-not $?) {
    throw "Fetcher public test configuration regeneration failed."
}
