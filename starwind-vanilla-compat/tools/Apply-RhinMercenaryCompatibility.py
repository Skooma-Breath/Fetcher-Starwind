"""Isolate Starwind's Rhin Ayari mercenary behavior from Tribunal's Calvus quest."""

from __future__ import annotations

import argparse
import copy
import importlib.util
import json
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("migrate_scripts", HERE / "Migrate-StarwindScripts.py")
MS = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MS)

RHIN_ID = "SW_Calvus Horatius"
RHIN_SCRIPT = "SW_RhinMercenary"
ANCHOR_ID = "SW_RhinMercAnchor01"
NEARBY_GLOBAL = "SW_RhinNearby"
CONTRACT_STUB = "SW_RhinContract"
JOURNAL_ID = "SW_Merc_Cal"
QUIT_JOURNAL = "SW_Merc_Cal_Quit"
CANTINA = "Tatooine, Cantina"
QUIT_INFO_ID = "9223372036854999002"

BYTECODE_MAP = {
    "King Hlaalu Helseth": ANCHOR_ID,
    "MercenaryNear": NEARBY_GLOBAL,
    "Contract_Calvus": CONTRACT_STUB,
    "Merc_Calvus_Quit": QUIT_JOURNAL,
    "Merc_Calvus": JOURNAL_ID,
}
EXPECTED_COUNTS = {
    "King Hlaalu Helseth": 2,
    "MercenaryNear": 5,
    "Contract_Calvus": 1,
    "Merc_Calvus_Quit": 1,
    "Merc_Calvus": 3,
}


def record(plugin: list, record_type: str, record_id: str):
    return next((item for item in plugin[1:] if item.get("type") == record_type and item.get("id", "").lower() == record_id.lower()), None)


def clone_quit_journal(tribunal: list) -> list:
    index = next(i for i, item in enumerate(tribunal) if item.get("type") == "Dialogue" and item.get("id", "").lower() == "merc_calvus_quit")
    dialogue = copy.deepcopy(tribunal[index])
    info = copy.deepcopy(tribunal[index + 1])
    if info.get("type") != "DialogueInfo":
        raise RuntimeError("Merc_Calvus_Quit journal INFO was not found.")
    dialogue["id"] = QUIT_JOURNAL
    info["id"] = QUIT_INFO_ID
    info["prev_id"] = ""
    info["next_id"] = ""
    info["text"] = info.get("text", "").replace("Calvus Horatius", "Rhin Ayari")
    return [dialogue, info]



def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--core-input", type=Path, required=True)
    parser.add_argument("--patch-input", type=Path, required=True)
    parser.add_argument("--tribunal", type=Path, required=True)
    parser.add_argument("--core-output", type=Path, required=True)
    parser.add_argument("--patch-output", type=Path, required=True)
    parser.add_argument("--report-output", type=Path, required=True)
    args = parser.parse_args()
    core = MS.read_json(args.core_input)
    patch = MS.read_json(args.patch_input)
    tribunal = MS.read_json(args.tribunal)
    zstd = MS.Zstd()

    source = record(tribunal, "Script", "Mercenary_Calvus")
    if source is None:
        raise RuntimeError("Tribunal Mercenary_Calvus script was not found.")
    script = copy.deepcopy(source)
    script["id"] = RHIN_SCRIPT
    text = script.get("text", "").replace("Mercenary_Calvus", RHIN_SCRIPT)
    text = text.replace("King Hlaalu Helseth", ANCHOR_ID).replace("MercenaryNear", NEARBY_GLOBAL).replace("Merc_Calvus_Quit", QUIT_JOURNAL).replace("Merc_Calvus", JOURNAL_ID)
    text = re.sub(r"(?i)(StopScript\s+)Contract_Calvus\b", r"\1" + CONTRACT_STUB, text)
    script["text"] = text

    raw = zstd.decompress(script["bytecode"])
    counts = {}
    for old, new in sorted(BYTECODE_MAP.items(), key=lambda item: len(item[0]), reverse=True):
        old_bytes = old.encode("cp1252")
        new_bytes = new.encode("cp1252")
        if len(old_bytes) != len(new_bytes):
            raise RuntimeError(f"Unsafe bytecode replacement: {old!r} -> {new!r}")
        counts[old] = raw.count(old_bytes)
        if counts[old] != EXPECTED_COUNTS[old]:
            raise RuntimeError(f"Expected {EXPECTED_COUNTS[old]} {old!r} references, found {counts[old]}.")
        raw = raw.replace(old_bytes, new_bytes)
    script["bytecode"] = zstd.compress(raw)

    nearby = copy.deepcopy(record(tribunal, "GlobalVariable", "MercenaryNear"))
    nearby["id"] = NEARBY_GLOBAL
    nearby["value"]["data"] = 0
    contract_stub = copy.deepcopy(record(tribunal, "Script", "DrathasScript"))
    contract_stub["id"] = CONTRACT_STUB
    contract_stub["text"] = contract_stub.get("text", "").replace("DrathasScript", CONTRACT_STUB)

    for plugin, label in ((core, "core"), (patch, "patch")):
        matches = [item for item in plugin[1:] if item.get("type") == "Npc" and item.get("id") == RHIN_ID]
        if len(matches) != 1 or matches[0].get("script") != "Mercenary_Calvus":
            raise RuntimeError(f"Unexpected {label} Rhin NPC/script state.")
        matches[0]["script"] = RHIN_SCRIPT

    core.extend([nearby, script, contract_stub])
    core.extend(clone_quit_journal(tribunal))

    patch.append({"type": "Static", "flags": "", "id": ANCHOR_ID, "mesh": "Ig\\Static\\InvisibleWallWide.nif"})
    cantina = next(item for item in patch[1:] if item.get("type") == "Cell" and item.get("name") == CANTINA)
    rhin_refs = [ref for ref in cantina.get("references", []) if ref.get("id") == RHIN_ID]
    if len(rhin_refs) != 1:
        raise RuntimeError(f"Expected one Rhin reference in the cantina, found {len(rhin_refs)}.")
    local_refs = [ref["refr_index"] for item in patch[1:] if item.get("type") == "Cell" for ref in item.get("references", []) if ref.get("mast_index") == 0]
    refnum = max(local_refs) + 1
    position = list(rhin_refs[0]["translation"])
    cantina["references"].append({"mast_index": 0, "refr_index": refnum, "id": ANCHOR_ID, "temporary": True, "scale": 0.01, "translation": [position[0], position[1], position[2] - 10000.0], "rotation": [0.0, 0.0, 0.0]})

    core[0]["num_objects"] = len(core) - 1
    patch[0]["num_objects"] = len(patch) - 1
    MS.write_json(core, args.core_output)
    MS.write_json(patch, args.patch_output)
    args.report_output.parent.mkdir(parents=True, exist_ok=True)
    args.report_output.write_text(json.dumps({"rhinNpcLinks": 2, "anchorRefNum": refnum, "bytecodeRewrites": counts}, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
