"Create private wearable bodypart variants for Starwind clothing/armor that reused vanilla bodyparts."
from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path


def canonical(path: str) -> str:
    return path.replace('/', '\\\\').lstrip('\\\\').lower()


def read_json(path: Path):
    with path.open(encoding='utf-8-sig') as source:
        return json.load(source)


def write_json(value, path: Path) -> None:
    with path.open('w', encoding='utf-8', newline='') as output:
        json.dump(value, output, ensure_ascii=False, separators=(',', ':'))


def private_bodypart_id(old: str, used: set[str]) -> str:
    base = 'SW_' + old
    candidate = base
    index = 0
    while candidate.lower() in used:
        index += 1
        candidate = f'{base}_{index}'
    used.add(candidate.lower())
    return candidate


def master_bodyparts(master: list, mesh_map: dict[str, str]) -> dict[str, tuple[dict, str]]:
    result: dict[str, tuple[dict, str]] = {}
    for record in master[1:]:
        if record.get('type') != 'Bodypart':
            continue
        mapped_mesh = mesh_map.get(canonical(record.get('mesh', '')))
        if mapped_mesh:
            result[record['id'].lower()] = (record, mapped_mesh)
    return result


def migrate(plugin: list, bodyparts: dict[str, tuple[dict, str]]) -> dict[str, int]:
    used_ids = {record.get('id', '').lower() for record in plugin[1:] if 'id' in record}
    added: dict[str, str] = {}
    stats = {'privateBodypartsAdded': 0, 'wearableSlotsRemapped': 0}
    for record in plugin[1:]:
        if record.get('type') not in {'Armor', 'Clothing'}:
            continue
        for part in record.get('biped_objects', []):
            for field in ('male_bodypart', 'female_bodypart'):
                old = part.get(field, '')
                if not old:
                    continue
                key = old.lower()
                source = bodyparts.get(key)
                if not source:
                    continue
                if key not in added:
                    clone = copy.deepcopy(source[0])
                    clone['id'] = private_bodypart_id(old, used_ids)
                    clone['mesh'] = source[1]
                    plugin.append(clone)
                    added[key] = clone['id']
                    stats['privateBodypartsAdded'] += 1
                part[field] = added[key]
                stats['wearableSlotsRemapped'] += 1
    plugin[0]['num_objects'] = len(plugin) - 1
    return stats


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--plugin', type=Path, required=True)
    parser.add_argument('--master', type=Path, required=True)
    parser.add_argument('--mappings', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()

    plugin = read_json(args.plugin)
    master = read_json(args.master)
    mappings = read_json(args.mappings)
    bodyparts = master_bodyparts(master, mappings.get('mesh', {}))
    stats = migrate(plugin, bodyparts)
    write_json(plugin, args.output)
    print(json.dumps({'plugin': str(args.output), **stats}, indent=2, sort_keys=True))


if __name__ == '__main__':
    main()
