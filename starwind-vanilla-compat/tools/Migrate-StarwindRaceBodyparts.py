"""Clone vanilla skin bodyparts onto Starwind-renamed races.

The character compatibility stage renames the playable race records and NPC race
links so Starwind no longer overrides Morrowind races. OpenMW selects naked body
parts by the actor's race, gender, body part, and skin/clothing type. If the
renamed races do not also have Skin Bodypart records, actors become head-only
after their clothing/armor is removed.

This script copies only Skin bodyparts from the official master races to the
renamed Starwind races with private SW_ IDs.
"""

from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path


SKIP_SKIN_PARTS = {"Head", "Hair"}


RACE_MAP = {
    "Argonian": "SW_Gungan",
    "Breton": "SW_Tarisian",
    "Dark Elf": "SW_Duros",
    "High Elf": "SW_Twilek",
    "Imperial": "SW_Coruscanti",
    "Khajiit": "SW_Cathar",
    "Nord": "SW_Mandalorian",
    "Orc": "SW_Rodian",
    "Redguard": "SW_Lothalite",
    "Wood Elf": "SW_Droid",
}


def read_json(path: Path):
    with path.open(encoding="utf-8-sig") as source:
        return json.load(source)


def write_json(path: Path, data) -> None:
    path.write_text(json.dumps(data, indent=2), encoding="utf-8")


def private_bodypart_id(old_id: str, used: set[str]) -> str:
    # TES3 IDs are byte-length constrained in practice. These vanilla bodypart
    # IDs are short enough for a simple SW_ prefix; still guard uniqueness.
    candidate = f"SW_{old_id}"
    if candidate.lower() not in used:
        return candidate
    index = 0
    while True:
        suffix = f"_{index:02d}"
        candidate = f"SW_{old_id}"
        max_len = max(1, 31 - len(suffix))
        if len(candidate) > max_len:
            candidate = candidate[:max_len]
        candidate += suffix
        if candidate.lower() not in used:
            return candidate
        index += 1


def clone_skin_bodyparts(master_records: list[dict], plugin_records: list[dict]) -> dict:
    used_ids = {record.get("id", "").lower() for record in plugin_records if "id" in record}
    existing_race_skin_keys = {
        (
            record.get("race", ""),
            record.get("data", {}).get("part", ""),
            record.get("data", {}).get("flags", ""),
            record.get("data", {}).get("bodypart_type", ""),
            record.get("mesh", "").lower(),
        )
        for record in plugin_records
        if record.get("type") == "Bodypart"
    }

    clones: list[dict] = []
    source_counts: dict[str, int] = {race: 0 for race in RACE_MAP}
    cloned_counts: dict[str, int] = {race: 0 for race in RACE_MAP.values()}

    for record in master_records:
        if record.get("type") != "Bodypart":
            continue
        old_race = record.get("race", "")
        new_race = RACE_MAP.get(old_race)
        if not new_race:
            continue
        data = record.get("data", {})
        if data.get("bodypart_type") != "Skin":
            continue
        if data.get("part") in SKIP_SKIN_PARTS:
            continue

        source_counts[old_race] += 1
        clone = copy.deepcopy(record)
        clone["id"] = private_bodypart_id(str(record["id"]), used_ids)
        clone["race"] = new_race
        used_ids.add(clone["id"].lower())

        key = (
            clone.get("race", ""),
            clone.get("data", {}).get("part", ""),
            clone.get("data", {}).get("flags", ""),
            clone.get("data", {}).get("bodypart_type", ""),
            clone.get("mesh", "").lower(),
        )
        if key in existing_race_skin_keys:
            continue
        existing_race_skin_keys.add(key)
        clones.append(clone)
        cloned_counts[new_race] += 1

    if not clones:
        raise RuntimeError("No Starwind race skin bodyparts were cloned.")

    # Put cloned skin bodyparts after the TES3 header and before game records that
    # reference races/NPCs. This keeps them in the plugin independent of masters.
    plugin_records[1:1] = clones

    missing = {old: count for old, count in source_counts.items() if count == 0}
    if missing:
        raise RuntimeError(f"No source skin bodyparts found for vanilla races: {sorted(missing)}")

    incomplete = {
        new: cloned_counts[new]
        for old, new in RACE_MAP.items()
        if cloned_counts[new] != source_counts[old]
    }
    if incomplete:
        raise RuntimeError(
            "Cloned skin bodypart count mismatch: "
            + ", ".join(f"{race}={count}" for race, count in sorted(incomplete.items()))
        )

    return {
        "skinBodypartsCloned": len(clones),
        "sourceCounts": source_counts,
        "clonedCounts": cloned_counts,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--plugin", type=Path, required=True)
    parser.add_argument("--master", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    plugin = read_json(args.plugin)
    master = read_json(args.master)
    stats = clone_skin_bodyparts(master[1:], plugin)
    write_json(args.output, plugin)
    print(json.dumps({"plugin": str(args.output), **stats}, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
