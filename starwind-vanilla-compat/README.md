# Starwind / vanilla compatibility

This is a generated compatibility build for the copy of Starwind in
`C:\openmwMods\UMO_stuff\starwind-modded`. It never edits the original Starwind
ESMs or assets. `tes3conv` converts the masters to JSON, the build tools make
targeted changes, and `tes3conv` writes replacement ESMs to `build\Data Files`.

## What the current build fixes

- Vanilla playable races, classes, birthsigns, body parts, and NPCs are preserved.
  Starwind equivalents use additive `SW_` IDs and remain selectable.
- The altered Tarhiel journal is additive; the original `bk_falljournal_unique`
  remains the vanilla record.
- All colliding game settings, skills, and magic effects are removed from the
  generated Starwind masters. These are global engine data and cannot safely
  differ by world.
- The two colliding globals and four Starwind deletion records for official
  startup scripts are removed. Nineteen collided Script records are renamed and
  their direct record links are updated.
- 978 genuinely changed BSA assets are overlaid with their official versions at
  the original paths. Starwind uses private copies of 247 meshes, 377 textures,
  and 352 icons where the generated ESMs reference them.
- The global Starwind Book UI textures are replaced by the 35 vanilla textures.
  The included OpenMW Lua script recognizes `SW_` datapad records by their
  datapad model and layers the Starwind tablet reader only over those records.

## Build

Run this from PowerShell after any source-mod change:

```powershell
Set-Location C:\openmwMods\UMO_stuff\starwind-vanilla-compat
.\tools\Build-All.ps1
```

The initial build is intentionally slow: it converts the masters and compares
1,020 BSA asset collisions byte-for-byte. Generated JSON is ignored because it
is reproducible. The installable outputs are:

- `build\Data Files\StarwindRemasteredV1.15.esm`
- `build\Data Files\StarwindRemasteredPatch.esm`
- `build\Starwind Vanilla Compat`

## Install in OpenMW

Make a dedicated profile; do not add these lines to the active Bardcraft/
Fetcher profile. Start with
`openmw-starwind-vanilla-compat.example.cfg`. The data-folder order is important:
the Starwind source must be lower priority than both generated folders.

Load only the generated ESM names shown below—do not load an additional copy of
the original Starwind core or patch:

```ini
content=Morrowind.esm
content=Tribunal.esm
content=Bloodmoon.esm
content=StarwindRemasteredV1.15.esm
content=StarwindRemasteredPatch.esm
content=StarwindVanillaCompat.omwscripts
```

The standard tablet script needs OpenMW 0.51 or later. OpenMW’s `UiModeChanged`
event provides the opened book object, which lets the script leave ordinary
books on the native UI while drawing the tablet over Starwind datapads.

## Test checklist

1. Start a new game in the dedicated profile. Confirm the original ten races
   are present and the Starwind races appear as separate choices.
2. Open a vanilla book (for example, the original Tarhiel journal) and verify
   the normal Morrowind book art and buttons are used.
3. In the console, run `player->additem "SW_AbbHutt" 1`, read the Old Datapad,
   and verify the teal tablet overlay is used. Escape should close it normally.
4. Equip a vanilla bow and crossbow. With the safe default
   `use additional anim sources = false`, both use normal vanilla animations.
5. Run `tools\Test-Compatibility.ps1` after a build. It re-reads both ESMs,
   verifies their master-size link, and verifies every asset and UI invariant.

## Experimental blaster animation redirect

Starwind blasters and vanilla crossbows share TES3’s `MarksmanCrossbow` weapon
type. The engine therefore cannot choose a native animation by weapon ID. The
optional Lua controller only intercepts Crossbow animation requests while an
`SW_` MarksmanCrossbow weapon is equipped and redirects to a private
`swblaster` group. Its generated KF files also mask Starwind’s global Bow and
Crossbow overrides, so vanilla weapons retain native groups.

To test it, change the profile to:

```ini
[Game]
use additional anim sources = true

content=StarwindVanillaCompatAnimationExperimental.omwscripts
```

This is opt-in because OpenMW notes that its hardcoded character controller can
alter or cancel scripted animation requests. If the private group is unavailable,
the controller deliberately falls back to the normal Crossbow animation.

## Important remaining work

The generated build is **not yet a teleport-safe dual-world build**. Starwind
still supplies 1,571 cell records and 7,642 dialogue-info records that collide
with the official masters. Relocating exterior cells also requires moving LAND,
pathgrids, reference coordinates, teleport destinations, AI travel packages,
and compiled MWScript destinations together. Dialogue INFO chains require their
own safe renumbering and topic handling, especially for special `Greeting`,
`Hello`, `Attack`, and `Service` dialogue records. Those two migrations must be
completed before travelling between a vanilla world and Starwind is safe.

The reports in `reports\` quantify every remaining collision; in particular,
`patch-override-summary.json`, `asset-bsa-collision-summary.json`, and
`asset-bsa-collision-comparison.csv` are the current audit baseline.
