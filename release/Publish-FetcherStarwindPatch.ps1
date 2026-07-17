[CmdletBinding()]
param(
    [string] $CompatibilityBuildRoot = "",
    [string] $OutputDirectory = "",
    [string] $PatchVersion = "2.1.1",
    [string] $Repository = "Skooma-Breath/Fetcher-Starwind",
    [string] $ReleaseTag = "fetcher-starwind-compat-patch-v2"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
if ([string]::IsNullOrWhiteSpace($CompatibilityBuildRoot)) {
    $CompatibilityBuildRoot = Join-Path $repositoryRoot "starwind-vanilla-compat\build"
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repositoryRoot "dist\starwind-patch-v$PatchVersion"
}

Push-Location $repositoryRoot
try {
    $pending = @(git status --porcelain)
    if ($LASTEXITCODE -ne 0) { throw "Could not inspect the Fetcher-Starwind worktree." }
    if ($pending.Count -ne 0) {
        throw "Refusing to publish from a dirty worktree. Commit or stash the current changes first."
    }
    $sourceCommit = (git rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $sourceCommit -notmatch "^[0-9a-f]{40}$") {
        throw "Could not resolve the Fetcher-Starwind source commit."
    }

    & (Join-Path $PSScriptRoot "Build-FetcherStarwindPatch.ps1") `
        -CompatibilityBuildRoot $CompatibilityBuildRoot `
        -OutputDirectory $OutputDirectory `
        -PatchVersion $PatchVersion `
        -SourceCommit $sourceCommit
    if (-not $?) { throw "Fetcher Starwind patch build failed." }

    $archivePath = Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) "fetcher-starwind-compat-patch-v2.zip"
    if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        throw "The patch builder did not create $archivePath"
    }

    if ([string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
        $gh = Get-Command gh -ErrorAction Stop
        $env:GH_TOKEN = (& $gh.Source auth token).Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
            throw "GitHub authentication is required. Run 'gh auth login' first."
        }
    }

    $notes = @"
Fetcher Starwind vanilla/multiplayer compatibility patch $PatchVersion.

This stable release is maintained independently from the Fetcher Simulator
client so patch updates do not require downloading a complete new client.
"@
    & (Join-Path $PSScriptRoot "Publish-StableGitHubRelease.ps1") `
        -Repository $Repository `
        -Tag $ReleaseTag `
        -TargetCommit $sourceCommit `
        -Title "Fetcher Starwind Compatibility Patch v2" `
        -Notes $notes `
        -Assets $archivePath
    if (-not $?) { throw "Fetcher Starwind release publication failed." }

    Write-Host "Published $archivePath"
    Write-Host "SHA256: $((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant())"
}
finally {
    Pop-Location
}
