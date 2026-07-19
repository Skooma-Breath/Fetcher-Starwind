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
- Vanilla bows and crossbows retain their native animation groups and all nine
  official draw/equip/fire cues. Starwind pistols use the private `swblaster`
  handgun group. Starwind rifles retain the native crossbow stance but use a
  private `swrifle` follow fragment that removes the bolt-reload tail. Both
  families use private copies of Starwind's original pull/fire sounds.
- Starwind's generic Czerka guard greeting is restricted to the private Czerka
  faction, the shared level-up cue and all eleven startup/loading screens are
  restored from Morrowind, and the rock obstructing the vanilla `coc "Suran"`
  arrival point is permanently deleted.

## Rebuild

Run after changing the source mod or build tools:

```powershell
Set-Location C:\serena_workspaces_directory\Fetcher-Starwind
$env:FETCHER_STARWIND_SOURCE_ROOT = 'C:\openmwMods\UMO_stuff'
.\starwind-vanilla-compat\tools\Build-All.ps1
```

The first build is slower because it converts the masters and compares BSA
assets. Finish with:

```powershell
.\starwind-vanilla-compat\tools\Test-Compatibility.ps1
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
4. Equip and fire a vanilla bow and crossbow. Both must use normal vanilla
   animation and audio. A Starwind pistol must use the private handgun
   animation and pistol audio; a Starwind rifle must use the rifle stance and
   rifle audio without reloading a crossbow bolt after each shot.
5. Observe a second multiplayer client firing both weapon families. Remote
   playback must make the same vanilla/blaster distinction.
6. Launch the game and change cells several times; all startup/loading images
   must be the official Morrowind set.
7. Run `tools\Test-Compatibility.ps1`; it must report zero generated
   master-key conflicts.

## Blaster animation and multiplayer routing

Starwind pistols are TES3 `MarksmanBow` weapons. The Fetcher multiplayer engine
selects the private `swblaster` handgun group only when the equipped weapon ID
starts with `SW_` and the group is available. Starwind rifles are
`MarksmanCrossbow` weapons and use the native crossbow group for their stance,
wind-up, and release. Their follow section is routed to the private `swrifle`
fragment so the crossbow bolt-reload tail is not played. For both weapon types,
the engine redirects animation sound text keys to private pistol or rifle cues. This happens in
every character controller, including remote-player NPC proxies, so remote
shots use the same animation/audio distinction and spatial playback.

The generated compatibility folder supplies both first- and third-person
private groups. Keep additional animation sources enabled:

```ini
[Game]
use additional anim sources = true
```

`StarwindVanillaCompat.omwscripts` also registers a player-side Lua redirect as
a compatibility fallback for builds without the engine route. If the private
handgun group is unavailable, both routes leave the normal bow animation
intact.
