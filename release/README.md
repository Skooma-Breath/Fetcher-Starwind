# Fetcher Starwind compatibility patch

This release overlays the Fetcher-maintained Starwind vanilla and multiplayer compatibility files without modifying the Nexus archive installed by UMO.

Version 2 also quarantines Starwind's root menu, cursor, scroll, and book UI textures outside the active data paths. This keeps Starwind world assets available while preventing its total-conversion UI skin from leaking into the shared vanilla multiplayer login and game interface.

`Textures/JMenuScreen.dds` is intentionally retained because `meshes/ig/activators/datapad.nif` uses it for the blue in-world datapad screen. Patch 2.0.1 restores it from older Fetcher quarantine directories when necessary.

Patch 2.0.1 also supplies the animation companions for all 21 creature models that `StarwindRemasteredV1.15.esm` relocates beneath `Meshes/starwind_compat/r`. OpenMW resolves external creature animations relative to the model directory, so relocating only the NIFs caused creatures such as the Mykal, Bolotaur, and Varactyl to translate through the world in static poses. The imperfect Fabricant's missing `x` model companion is included as well. Release builds validate every required companion by SHA-256.

Patch 2.1 relocates Starwind's standard `Music/Battle`, `Music/Explore`, and `Music/Special` overrides into the isolated `Music/Starwind` namespace at install time. This restores Morrowind's title music at the main menu and lets the bundled OpenMW Lua router select Starwind music only for cells owned by `StarwindRemasteredPatch.esm`. Outside those cells, the router combines the normal Morrowind explore/battle directories with any additional namespaced explore/battle tracks supplied by projects such as Tamriel Rebuilt or Project Cyrodiil.

Patch 2.1.1 restricts Starwind's generic Czerka guard greeting to the private Czerka faction, restores Morrowind's vanilla level-up sound, and permanently deletes the vanilla rock reference that obstructs the `coc "Suran"` arrival point.

Patch 2.1.2 restores all eleven official Morrowind startup and loading splash screens at the high-priority compatibility layer. It also keeps vanilla bow and crossbow animation/audio intact while routing Starwind pistols and rifles through private animation and sound sources.

Patch 2.2.0 changes the release to a redistribution-safe transformer package. Official Morrowind meshes, textures, icons, sounds, and splash screens are excluded from the ZIP. The installer copies or extracts them from the tester's own configured Morrowind installation and recreates the official NIF variants by rewriting their embedded texture paths. Every reconstructed result is checked against the release manifest by SHA-256 before installation continues.

Patch 2.2.1 fixes UTF-8 dialogue corruption caused by Windows PowerShell reading generated JSON as the system ANSI code page. All build stages now read JSON explicitly as UTF-8, and verification rejects regressions in Tatooine Assoll's greeting.

The patch is portable. Its applier receives the tester installation root and discovered Starwind data root as parameters; it contains no machine-specific paths. Installation is staged and swapped into `Data Files/fetcher-starwind-compat`, with packaged payload hashes and locally reconstructed file hashes verified before any existing patch is replaced.

For testers migrating from the previously published updater, the install root can also be discovered by walking upward from the UMO-managed Starwind data directory. The release includes the legacy manifest alias expected by that updater and regenerates `openmw.cfg` after applying the overlay, so the first `Update-Fetcher-Simulator.bat` run completes the migration.

Build a release archive from the compatibility project's `build` directory. The default version is read from `PATCH_VERSION.txt`; pass `-PatchVersion` only for an intentional override.

```powershell
.\Build-FetcherStarwindPatch.ps1 `
  -CompatibilityBuildRoot C:\path\to\starwind-vanilla-compat\build `
  -OutputDirectory C:\path\to\release-output `
  -SourceCommit 7070c4f
```

The package contains the final compatibility plugins and only the non-Morrowind portion of the `Starwind Vanilla Compat` overlay. Destinations listed in `reports/morrowind-local-assets.json` are deliberately excluded and reconstructed on the tester's machine. Numbered intermediate ESM build artifacts and the source `Music` directory are excluded.
