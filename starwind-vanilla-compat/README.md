# Starwind / Vanilla Compatibility

This project converts the Starwind core master to JSON with `tes3conv`, audits each
record that collides with Morrowind, Tribunal, or Bloodmoon, and builds a separate
compatible Starwind master. The original mod files are never edited.

## First milestone: races

The Starwind core replaces the ten playable Morrowind races by reusing their IDs.
`tools/Build-BodypartCompatibleStarwind.ps1` builds on the character migration and
also isolates every altered vanilla body part, updating Starwind NPC heads/hair and
equipment body-part links. It preserves original vanilla character appearances while
keeping the Starwind additions selectable.

## Workflow

1. Run `tools/Convert-StarwindSources.ps1` to convert the core master, patch, and
   official masters.
2. Run `tools/Analyze-StarwindOverrides.ps1` to regenerate the record-overlap report.
3. Run `tools/Build-CharacterCompatibleStarwind.ps1`, then `tools/Build-BodypartCompatibleStarwind.ps1`, to build matching core and patch files.

The `converted` directory holds source JSON; the `build` directory holds generated
plugins. Do not load both the original core master and a generated replacement.
