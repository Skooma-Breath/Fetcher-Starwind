# Fetcher Starwind compatibility patch

This repository owns Fetcher's Starwind/vanilla compatibility source, build
tools, release packaging, and the stable patch release consumed by Fetcher
clients. Keeping it separate from the Fetcher Simulator/OpenMW repository lets
Starwind patches update without republishing the complete portable client.

## Layout

- `starwind-vanilla-compat/` contains the record and asset migration pipeline,
  generated compatibility ESMs, reports, and verification suite.
- `release/` contains the portable patch builder, installer, music router, and
  stable-release publisher.
- `starwind-modded/` is local source material. Only the two source ESMs are
  tracked; the downloaded Starwind assets and official Morrowind data remain
  local and are never uploaded by this repository.

## Build and verify

The compatibility build requires legally installed copies of Morrowind and
Starwind 3.1. From this repository root:

```powershell
$env:FETCHER_STARWIND_SOURCE_ROOT = 'C:\openmwMods\UMO_stuff'
.\starwind-vanilla-compat\tools\Build-All.ps1
```

`FETCHER_STARWIND_SOURCE_ROOT` points at the local source checkout containing
`starwind-modded\tes3conv.exe` and the downloaded Starwind assets. It is not
needed when that local source material already lives inside this repository.

The final build step re-reads both generated ESMs and verifies record
isolation, intentional overrides, and required vanilla asset hashes.

## Publish the stable patch

A push to `main` runs the validation workflow and then automatically rebuilds and replaces `fetcher-starwind-compat-patch-v2.zip` on the stable `fetcher-starwind-compat-patch-v2` prerelease. The workflow publishes only when its commit is still the latest remote `main`, preventing an older queued run from overwriting a newer patch.

The patch version is read from `release/PATCH_VERSION.txt`. Manual publication remains available from a clean worktree:

```powershell
.\release\Publish-FetcherStarwindPatch.ps1
```

Fetcher clients compare the GitHub asset digest and download only the changed Starwind patch.
