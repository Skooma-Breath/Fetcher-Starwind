"""Relocate Starwind's worldspace without changing the original masters.

Exterior cells are translated east by a fixed TES3 cell offset. Interior cells
receive unique same-byte-length names, allowing both MWScript source and its
compiled bytecode strings to be safely rewritten. Missing remote LAND records
are cloned from the original Morrowind master so the relocated Starwind cells
retain their terrain.
"""

from __future__ import annotations

import argparse
import base64
import copy
import ctypes
import json
import re
from pathlib import Path


CELL_SIZE = 8192
X_OFFSET = 256
Y_OFFSET = 0
ZSTD_DLL = Path(r"C:\Program Files\OpenMW 0.50.0\zstd.dll")


class Zstd:
    def __init__(self) -> None:
        if not ZSTD_DLL.is_file():
            raise FileNotFoundError(f'Unable to find zstd runtime: {ZSTD_DLL}')
        self.lib = ctypes.CDLL(str(ZSTD_DLL))
        self.lib.ZSTD_getFrameContentSize.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
        self.lib.ZSTD_getFrameContentSize.restype = ctypes.c_ulonglong
        self.lib.ZSTD_decompress.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t]
        self.lib.ZSTD_decompress.restype = ctypes.c_size_t
        self.lib.ZSTD_decompressBound.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
        self.lib.ZSTD_decompressBound.restype = ctypes.c_ulonglong
        self.lib.ZSTD_compressBound.argtypes = [ctypes.c_size_t]
        self.lib.ZSTD_compressBound.restype = ctypes.c_size_t
        self.lib.ZSTD_compress.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
        self.lib.ZSTD_compress.restype = ctypes.c_size_t
        self.lib.ZSTD_isError.argtypes = [ctypes.c_size_t]
        self.lib.ZSTD_isError.restype = ctypes.c_uint
        self.lib.ZSTD_getErrorName.argtypes = [ctypes.c_size_t]
        self.lib.ZSTD_getErrorName.restype = ctypes.c_char_p

    def assert_success(self, result: int) -> int:
        if self.lib.ZSTD_isError(result):
            raise RuntimeError(self.lib.ZSTD_getErrorName(result).decode('ascii'))
        return result

    def decompress(self, encoded: str) -> bytes:
        source = base64.b64decode(encoded)
        source_buffer = ctypes.create_string_buffer(source)
        size = self.lib.ZSTD_getFrameContentSize(source_buffer, len(source))
        if size >= (1 << 64) - 2:
            size = self.lib.ZSTD_decompressBound(source_buffer, len(source))
        if size == 0 or size >= (1 << 64) - 2:
            raise RuntimeError('MWScript bytecode Zstd frame has no usable uncompressed-size bound.')
        destination = ctypes.create_string_buffer(size)
        result = self.assert_success(self.lib.ZSTD_decompress(destination, size, source_buffer, len(source)))
        if result > size:
            raise RuntimeError(f'MWScript bytecode decompression exceeded its buffer: {result} > {size}.')
        return destination.raw[:result]

    def compress(self, raw: bytes) -> str:
        source_buffer = ctypes.create_string_buffer(raw)
        capacity = self.lib.ZSTD_compressBound(len(raw))
        destination = ctypes.create_string_buffer(capacity)
        result = self.assert_success(self.lib.ZSTD_compress(destination, capacity, source_buffer, len(raw), 3))
        return base64.b64encode(destination.raw[:result]).decode('ascii')


def read_json(path: Path):
    with path.open(encoding='utf-8-sig') as input_file:
        return json.load(input_file)


def write_json(value, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('w', encoding='utf-8', newline='') as output_file:
        json.dump(value, output_file, ensure_ascii=False, separators=(',', ':'))


def is_interior(cell: dict) -> bool:
    return 'IS_INTERIOR' in cell['data']['flags']


def cell_key(grid: list[int]) -> tuple[int, int]:
    return int(grid[0]), int(grid[1])


def shifted_grid(grid: list[int]) -> list[int]:
    return [int(grid[0]) + X_OFFSET, int(grid[1]) + Y_OFFSET]


def interior_name(old: str, used: set[str]) -> str:
    if len(old.encode('cp1252')) < 5:
        raise RuntimeError(f'Interior cell name is too short for a same-byte-length SW_ prefix: {old!r}')
    # Keep the beginning recognizable while reserving the SW_ namespace.  If
    # two names only differ in their final characters, vary the final two bytes.
    candidate = 'SW_' + old[:-3]
    if candidate.lower() not in used:
        used.add(candidate.lower())
        return candidate
    alphabet = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ'
    stem = 'SW_' + old[:-5]
    for first in alphabet:
        for second in alphabet:
            candidate = stem + first + second
            if len(candidate.encode('cp1252')) == len(old.encode('cp1252')) and candidate.lower() not in used:
                used.add(candidate.lower())
                return candidate
    raise RuntimeError(f'Could not create a unique same-length name for interior cell {old!r}')


def master_interior_names(masters: list[list]) -> set[str]:
    names: set[str] = set()
    for master in masters:
        for record in master[1:]:
            if record['type'] == 'Cell' and is_interior(record) and record.get('name'):
                names.add(record['name'].lower())
    return names


def build_maps(core: list, patch: list, reports: Path, masters: list[list]) -> tuple[set[tuple[int, int]], dict[str, str], dict[str, str]]:
    records = core[1:] + patch[1:]
    exterior = {cell_key(record['data']['grid']) for record in records if record['type'] == 'Cell' and not is_interior(record)}
    official_interiors = master_interior_names(masters)
    starwind_interior_names = [
        record['name']
        for record in records
        if record['type'] == 'Cell' and is_interior(record) and record.get('name')
    ]
    # Keep non-conflicting Starwind interiors on their original names.  Reserve
    # those names plus official names so generated SW_ conflict names cannot
    # collide with anything that remains in the final load order.
    used_names: set[str] = set(official_interiors)
    used_names.update(name.lower() for name in starwind_interior_names if name.lower() not in official_interiors)
    interiors: dict[str, str] = {}
    for old in starwind_interior_names:
        old_lower = old.lower()
        if old_lower in official_interiors and old_lower not in interiors:
            interiors[old_lower] = interior_name(old, used_names)

    region_ids: set[str] = set()
    for report_name in ('overridden-records.csv', 'patch-overridden-records.csv'):
        with (reports / report_name).open(newline='', encoding='utf-8-sig') as report_file:
            for row in __import__('csv').DictReader(report_file):
                if row['RecordType'] == 'Region':
                    region_ids.add(row['Id'])
    regions = {old.lower(): f'SW_{old}' for old in region_ids}
    return exterior, interiors, regions


def remap_script_bytes(zstd: Zstd, encoded: str, byte_map: list[tuple[bytes, bytes]]) -> tuple[str, int]:
    raw = zstd.decompress(encoded)
    changes = 0
    for old, new in byte_map:
        # Cell names in compiled MWScript string constants retain their source
        # casing, whereas the lookup map is intentionally case-insensitive.
        # Names are exactly the same byte length, so this does not disturb any
        # bytecode offsets that follow the string constants.
        raw, count = re.subn(
            rb'(?<![A-Za-z0-9_-])' + re.escape(old) + rb'(?![A-Za-z0-9_-])',
            new,
            raw,
            flags=re.IGNORECASE,
        )
        changes += count
    return zstd.compress(raw), changes


def replace_names(text: str, mappings: dict[str, str]) -> tuple[str, int]:
    changes = 0
    # Longest names first avoids replacing the shorter prefix of a longer cell.
    for old_lower, new in sorted(mappings.items(), key=lambda item: len(item[0]), reverse=True):
        old = old_lower  # Source names are found case-insensitively below.
        pattern = re.compile(r'(?<![A-Za-z0-9_-])' + re.escape(old) + r'(?![A-Za-z0-9_-])', re.IGNORECASE)
        text, count = pattern.subn(new, text)
        changes += count
    return text, changes


def shift_translation(translation: list) -> None:
    translation[0] += X_OFFSET * CELL_SIZE
    translation[1] += Y_OFFSET * CELL_SIZE


def remap_reference_destination(reference: dict, interiors: dict[str, str], stats: dict[str, int], shift_exterior: bool) -> None:
    destination = reference.get('destination')
    if not destination:
        return
    cell = destination.get('cell', '')
    if cell == '':
        if shift_exterior:
            shift_translation(destination['translation'])
            stats['exteriorTeleportDestinationsShifted'] += 1
        return
    mapped = interiors.get(cell.lower())
    if mapped:
        destination['cell'] = mapped
        stats['interiorDestinationsRemapped'] += 1


def migrate_plugin(plugin: list, interiors: dict[str, str], regions: dict[str, str], zstd: Zstd) -> dict[str, int]:
    stats = {
        'exteriorCells': 0,
        'interiorCells': 0,
        'cellReferencesShifted': 0,
        'exteriorTeleportDestinationsShifted': 0,
        'interiorDestinationsRemapped': 0,
        'npcTravelDestinationsShifted': 0,
        'speakerCellsRemapped': 0,
        'dialogueCellFiltersRemapped': 0,
        'pathgridsShifted': 0,
        'landscapesShifted': 0,
        'regionsRemapped': 0,
        'scriptSourceTokens': 0,
        'scriptBytecodeTokens': 0,
        'landscapeTexturesRemoved': 0,
    }
    byte_map = [(old.encode('cp1252'), new.encode('cp1252')) for old, new in sorted(interiors.items(), key=lambda item: len(item[0]), reverse=True)]
    kept = [plugin[0]]
    for record in plugin[1:]:
        if record['type'] == 'LandscapeTexture' and record.get('id', '').lower() in {
            'tx_bc_mud.tga', 'tx_bc_undergrowth.tga', 'tx_bc_rockyscrub.tga', 'tx_bc_rock_03.tga', 'tx_bm_rock_dirt_01.dds'
        }:
            stats['landscapeTexturesRemoved'] += 1
            continue
        if record['type'] == 'Cell':
            interior = is_interior(record)
            if interior:
                mapped = interiors.get(record['name'].lower())
                if mapped:
                    record['name'] = mapped
                    stats['interiorCells'] += 1
            else:
                record['data']['grid'] = shifted_grid(record['data']['grid'])
                stats['exteriorCells'] += 1
            for reference in record.get('references', []):
                if not interior and 'translation' in reference:
                    shift_translation(reference['translation'])
                    stats['cellReferencesShifted'] += 1
                remap_reference_destination(reference, interiors, stats, shift_exterior=not interior)
            if record.get('region', '').lower() in regions:
                record['region'] = regions[record['region'].lower()]
                stats['regionsRemapped'] += 1
        elif record['type'] == 'Landscape':
            record['grid'] = shifted_grid(record['grid'])
            stats['landscapesShifted'] += 1
        elif record['type'] == 'PathGrid':
            if record.get('cell', '') == '':
                record['data']['grid'] = shifted_grid(record['data']['grid'])
                stats['pathgridsShifted'] += 1
            else:
                mapped = interiors.get(record['cell'].lower())
                if mapped:
                    record['cell'] = mapped
                    stats['interiorDestinationsRemapped'] += 1
        elif record['type'] == 'Npc':
            for destination in record.get('travel_destinations', []):
                if destination.get('cell', '') == '':
                    shift_translation(destination['translation'])
                    stats['npcTravelDestinationsShifted'] += 1
                else:
                    mapped = interiors.get(destination['cell'].lower())
                    if mapped:
                        destination['cell'] = mapped
                        stats['interiorDestinationsRemapped'] += 1
        elif record['type'] == 'DialogueInfo':
            mapped = interiors.get(record.get('speaker_cell', '').lower())
            if mapped:
                record['speaker_cell'] = mapped
                stats['speakerCellsRemapped'] += 1
            for select in record.get('filters', []):
                if select.get('filter_type') in {'Cell', 'NotCell'}:
                    mapped = interiors.get(select.get('id', '').lower())
                    if mapped:
                        select['id'] = mapped
                        stats['dialogueCellFiltersRemapped'] += 1
            if record.get('script_text'):
                record['script_text'], changed = replace_names(record['script_text'], interiors)
                stats['scriptSourceTokens'] += changed
        elif record['type'] == 'Region':
            mapped = regions.get(record.get('id', '').lower())
            if mapped:
                record['id'] = mapped
                stats['regionsRemapped'] += 1
        elif record['type'] == 'Script':
            record['text'], changed = replace_names(record.get('text', ''), interiors)
            stats['scriptSourceTokens'] += changed
            if changed:
                record['bytecode'], byte_changes = remap_script_bytes(zstd, record['bytecode'], byte_map)
                stats['scriptBytecodeTokens'] += byte_changes
        kept.append(record)
    kept[0]['num_objects'] = len(kept) - 1
    plugin[:] = kept
    return stats


def clone_missing_landscape(master: list, core: list, exterior: set[tuple[int, int]], source_landscape_grids: set[tuple[int, int]]) -> int:
    master_lands = {
        cell_key(record['grid']): record for record in master[1:] if record['type'] == 'Landscape'
    }
    cloned = 0
    for grid in sorted(exterior):
        if grid in source_landscape_grids:
            continue
        base = master_lands.get(grid)
        if base:
            clone = copy.deepcopy(base)
            clone['grid'] = shifted_grid(base['grid'])
            core.append(clone)
            cloned += 1
    core[0]['num_objects'] = len(core) - 1
    return cloned


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--core-input', type=Path, required=True)
    parser.add_argument('--patch-input', type=Path, required=True)
    parser.add_argument('--morrowind-master', type=Path, required=True)
    parser.add_argument('--reports', type=Path, required=True)
    parser.add_argument('--core-output', type=Path, required=True)
    parser.add_argument('--patch-output', type=Path, required=True)
    parser.add_argument('--map-output', type=Path, required=True)
    args = parser.parse_args()

    core = read_json(args.core_input)
    patch = read_json(args.patch_input)
    morrowind_master = read_json(args.morrowind_master)
    masters = [morrowind_master]
    for master_name in ('Tribunal.json', 'Bloodmoon.json'):
        master_path = args.morrowind_master.parent / master_name
        if master_path.is_file():
            masters.append(read_json(master_path))
    exterior, interiors, regions = build_maps(core, patch, args.reports, masters)
    source_landscape_grids = {
        cell_key(record['grid']) for record in core[1:] + patch[1:] if record['type'] == 'Landscape'
    }
    zstd = Zstd()
    core_stats = migrate_plugin(core, interiors, regions, zstd)
    patch_stats = migrate_plugin(patch, interiors, regions, zstd)
    cloned_lands = clone_missing_landscape(morrowind_master, core, exterior, source_landscape_grids)

    # Validate the generated cell namespace before output is written.
    all_records = core[1:] + patch[1:]
    relocated = {cell_key(record['data']['grid']) for record in all_records if record['type'] == 'Cell' and not is_interior(record)}
    if relocated.intersection(exterior):
        raise RuntimeError('Relocated exterior cell grid still intersects the original Starwind grid.')
    interior_values = [record['name'].lower() for record in all_records if record['type'] == 'Cell' and is_interior(record)]
    remaining_conflicts = sorted(set(value for value in interior_values if value in master_interior_names(masters)))
    if remaining_conflicts:
        raise RuntimeError('Starwind interior cell conflicts remain after selective rename: ' + ', '.join(remaining_conflicts[:20]))
    renamed_values = {value.lower() for value in interiors.values()}
    non_prefixed_renames = sorted(value for value in renamed_values if not value.startswith('sw_'))
    if non_prefixed_renames:
        raise RuntimeError('Selective Starwind interior rename generated non-SW_ names: ' + ', '.join(non_prefixed_renames[:20]))

    write_json(core, args.core_output)
    write_json(patch, args.patch_output)
    payload = {
        'offsetCells': {'x': X_OFFSET, 'y': Y_OFFSET},
        'offsetUnits': {'x': X_OFFSET * CELL_SIZE, 'y': Y_OFFSET * CELL_SIZE},
        'originalExteriorCellCount': len(exterior),
        'interiorCellNames': interiors,
        'regionIds': regions,
        'core': core_stats,
        'patch': patch_stats,
        'clonedMorrowindLandRecords': cloned_lands,
    }
    write_json(payload, args.map_output)
    print(json.dumps(payload, indent=2, sort_keys=True))


if __name__ == '__main__':
    main()
