# Starwind / Vanilla Compatibility

This project converts the Starwind core master to JSON with `tes3conv`, audits each
record that collides with Morrowind, Tribunal, or Bloodmoon, and builds a separate
compatible Starwind master. The original mod files are never edited.

## First milestone: races

The Starwind core replaces the ten playable Morrowind races by reusing their IDs.
`tools/Build-CharacterCompatibleStarwind.ps1` gives the Starwind race, class, and
birthsign records new `SW_` IDs, updates their NPC/dialogue assignments in both the
core and remaster patch, and updates the patch's core-master byte count. It preserves
all vanilla character options and keeps the Starwind additions selectable.

## Workflow

1. Run `tools/Convert-StarwindSources.ps1` to convert the core master, patch, and
   official masters.
2. Run `tools/Analyze-StarwindOverrides.ps1` to regenerate the record-overlap report.
3. Run `tools/Build-CharacterCompatibleStarwind.ps1` to build matching core and patch files.

The `converted` directory holds source JSON; the `build` directory holds generated
plugins. Do not load both the original core master and a generated replacement.
