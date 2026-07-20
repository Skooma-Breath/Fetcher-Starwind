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

The final build step re-reads both generated ESMs, verifies record isolation and intentional overrides, and writes `reports/morrowind-local-assets.json`. That manifest identifies every compatibility file that must be reconstructed from the tester's own Morrowind installation.

## Redistribution-safe package

The release ZIP does not contain official Morrowind meshes, textures, icons, sounds, or splash screens. `Build-FetcherStarwindPatch.ps1` excludes every destination listed in `morrowind-local-assets.json` and includes only the reconstruction recipe.

During installation, the patch applier:

1. Finds the Morrowind data directories already configured in `openmw.cfg`.
2. Copies loose official files or extracts them from the tester's own BSA archives with the shipped `bsatool.exe`.
3. Recreates official NIF variants by changing only their length-prefixed texture paths.
4. Verifies every locally reconstructed result by SHA-256 before replacing the installed patch.

Modified Starwind assets, Fetcher-authored scripts, generated compatibility plugins, and other non-Morrowind payload files remain in the package.

## Publish the stable patch

GitHub Actions validates the tracked scripts, plugins, version, and local-reconstruction manifest. It does not build the release because the non-Morrowind compatibility payload is generated from local Starwind source material that is intentionally not committed.

After committing a verified build, publish from the clean local worktree that has the required source material:

```powershell
.\release\Publish-FetcherStarwindPatch.ps1
```

The patch version is read from `release/PATCH_VERSION.txt`. The publisher builds the redistribution-safe ZIP, replaces `fetcher-starwind-compat-patch-v2.zip` on the stable prerelease, and moves the stable tag only after the upload succeeds. Fetcher clients compare the GitHub asset digest and download only the changed Starwind patch.
