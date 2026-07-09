# Starwind / vanilla compatibility build

This build lets Starwind 3.1 and the original Morrowind, Tribunal, and
Bloodmoon masters load together without Starwind replacing vanilla records or
assets. It never edits the source Starwind folder.

The generated ESMs are written to `build\Data Files`; their record names match
the original Starwind ESM names so they can replace the source versions through
OpenMW's data-folder priority.

## Compatibility work included

- The ten vanilla races, vanilla classes, birthsigns, body parts, NPCs,
  globals, game settings, skills, and magic effects remain vanilla. Starwind
  equivalents are additive private records.
- The Starwind exterior is moved 256 cells east (2,097,152 world units). Its
  443 interior cells, regions, teleports, AI destinations, landscape records,
  and both source and compiled MWScript cell names are moved together. Missing
  remote terrain is cloned from `Morrowind.esm`.
- Starwind dialogue is detached from official dialogue: 54 reused DIAL records
  are private and all 14,640 Starwind INFO records have a private linked chain.
- Every remaining master-key collision is isolated: 201 records across spells,
  creatures, factions, sound, containers, lights, doors, items, and levelled
  lists. The build repairs structured references and same-byte-length compiled
  MWScript identifiers.
- 978 changed BSA paths are overlaid with the official asset at the original
  VFS path. Starwind uses its own copies of 247 meshes, 377 textures, and 352
  icons where needed.
- Vanilla books use vanilla book art. The included Lua script recognizes only
  Starwind datapads and draws the tablet-reader layer for them.
- Vanilla bow and crossbow animations remain untouched by default. The optional
  Lua/KF blaster redirect is supplied separately.

## Rebuild

Run after changing the source mod or build tools:

```powershell
Set-Location C:\openmwMods\UMO_stuff\starwind-vanilla-compat
.\tools\Build-All.ps1
```

The first build is slower because it converts the masters and compares BSA
assets. Finish with:

```powershell
.\tools\Test-Compatibility.ps1
```

The test re-reads both generated ESMs and fails if any record key still
conflicts with Morrowind, Tribunal, or Bloodmoon.

## Install and launch

1. Use OpenMW 0.51 or newer and make a dedicated profile. Do not add this to
   the active Fetcher/Bardcraft profile.
2. Copy the contents of
   `openmw-starwind-vanilla-compat.example.cfg` into that profile's
   `openmw.cfg`, preserving its `data=` order.
3. Ensure this is the complete content order. Do not add another source copy
   of either Starwind ESM:

   ```ini
   content=Morrowind.esm
   content=Tribunal.esm
   content=Bloodmoon.esm
   content=StarwindRemasteredV1.15.esm
   content=StarwindRemasteredPatch.esm
   content=StarwindVanillaCompat.omwscripts
   ```

The source Starwind data directory stays below the two generated folders so it
provides Starwind-only assets, while the generated directories win for vanilla
asset paths and generated ESMs.

## Moving between worlds

Start a normal new game to verify vanilla Morrowind. To enter Starwind, open
the console and run:

```text
coc "SW_Tatoo"
```

To return to vanilla, for example:

```text
coc "Balmora"
```

The full original-to-private interior mapping is in
`reports\world-migration-map.json`. Its same-byte-length IDs deliberately keep
compiled MWScript safe, so some names are abbreviated.

## Smoke-test checklist

1. Begin a new vanilla game. Seyda Neen, its terrain, NPCs, book UI, and the
   original ten races should look and behave normally.
2. Use the Starwind console command above. Confirm the Starwind interior loads;
   then return with `coc "Balmora"`.
3. Open a vanilla book and verify the native Morrowind reader appears. Then run
   `player->additem "SW_AbbHutt" 1`, open the Old Datapad, and verify the teal
   tablet layer appears only for that datapad.
4. Equip a vanilla bow and crossbow. With the default configuration both use
   normal vanilla animation groups.
5. Run `tools\Test-Compatibility.ps1`; it must report zero generated
   master-key conflicts.

## Optional blaster animation redirect

Starwind blasters and vanilla crossbows share TES3's `MarksmanCrossbow` weapon
type, so this is intentionally opt-in. Add the following to the dedicated
profile to have the Lua controller request the private `swblaster` group only
for equipped private Starwind blasters:

```ini
[Game]
use additional anim sources = true

content=StarwindVanillaCompatAnimationExperimental.omwscripts
```

If that private group is unavailable, the script falls back to the normal
crossbow animation. Leave the option disabled for the safest all-vanilla bow
and crossbow behavior.
