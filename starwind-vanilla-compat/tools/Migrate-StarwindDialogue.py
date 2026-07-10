"""Detach Starwind dialogue records and INFO chains from the vanilla masters.

Dialogue records are grouped with their following INFO records in TES3 files.
The conversion preserves that ordering, but gives every colliding DIAL record a
private, same-byte-length ID and every Starwind INFO a new ID.  Same-length
DIAL IDs let us safely repair the corresponding compiled MWScript string
constants without changing bytecode offsets.
"""

from __future__ import annotations

import argparse
import base64
import ctypes
import json
import re
from pathlib import Path


ZSTD_DLL = Path(r"C:\Program Files\OpenMW 0.50.0\zstd.dll")
INFO_START = 9_223_372_036_854_000_000
ALPHABET = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ'
SHARED_DIALOGUE_TYPES = {'Greeting', 'Voice'}


class Zstd:
    def __init__(self) -> None:
        if not ZSTD_DLL.is_file():
            raise FileNotFoundError(f'Unable to find zstd runtime: {ZSTD_DLL}')
        self.lib = ctypes.CDLL(str(ZSTD_DLL))
        self.lib.ZSTD_getFrameContentSize.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
        self.lib.ZSTD_getFrameContentSize.restype = ctypes.c_ulonglong
        self.lib.ZSTD_decompressBound.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
        self.lib.ZSTD_decompressBound.restype = ctypes.c_ulonglong
        self.lib.ZSTD_decompress.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t]
        self.lib.ZSTD_decompress.restype = ctypes.c_size_t
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
        output = ctypes.create_string_buffer(size)
        result = self.assert_success(self.lib.ZSTD_decompress(output, size, source_buffer, len(source)))
        return output.raw[:result]

    def compress(self, raw: bytes) -> str:
        source = ctypes.create_string_buffer(raw)
        capacity = self.lib.ZSTD_compressBound(len(raw))
        output = ctypes.create_string_buffer(capacity)
        result = self.assert_success(self.lib.ZSTD_compress(output, capacity, source, len(raw), 3))
        return base64.b64encode(output.raw[:result]).decode('ascii')


def read_json(path: Path):
    with path.open(encoding='utf-8-sig') as source:
        return json.load(source)


def write_json(value, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('w', encoding='utf-8', newline='') as output:
        json.dump(value, output, ensure_ascii=False, separators=(',', ':'))


def digits(value: int, width: int) -> str:
    result = ''
    for _ in range(width):
        result = ALPHABET[value % len(ALPHABET)] + result
        value //= len(ALPHABET)
    return result


def private_dial_id(old: str, used: set[str]) -> str:
    """Return a unique CP1252 same-byte-length private dialogue identifier."""
    width = len(old.encode('cp1252'))
    if width < 3:
        raise RuntimeError(f'Dialogue ID is too short to migrate safely: {old!r}')
    prefix = 'SW_' if width >= 4 else 'S'
    room = width - len(prefix)
    first = (prefix + old)[:width]
    if first.lower() not in used:
        used.add(first.lower())
        return first
    for sequence in range(len(ALPHABET) ** room):
        candidate = prefix + digits(sequence, room)
        if candidate.lower() not in used:
            used.add(candidate.lower())
            return candidate
    raise RuntimeError(f'No same-length private dialogue ID is available for {old!r}')


def master_records(master_paths: list[Path], record_type: str) -> dict[str, dict]:
    result: dict[str, dict] = {}
    for path in master_paths:
        for record in read_json(path)[1:]:
            if record['type'] == record_type:
                result[record['id'].lower()] = record
    return result


def make_maps(core: list, patch: list, master_dials: dict[str, dict], master_infos: set[str]) -> tuple[dict[str, str], dict[str, str]]:
    dials = [record for plugin in (core, patch) for record in plugin[1:] if record['type'] == 'Dialogue']
    used = set(master_dials) | {record['id'].lower() for record in dials if record['id'].lower() not in master_dials}
    dial_map: dict[str, str] = {}
    for record in dials:
        old = record['id']
        key = old.lower()
        if key not in master_dials or key in dial_map:
            continue
        if record['dialogue_type'] != master_dials[key]['dialogue_type']:
            raise RuntimeError(f'Dialogue type conflict for {old!r}; refusing to change its meaning.')
        if record['dialogue_type'] in SHARED_DIALOGUE_TYPES:
            # Greeting and voice dialogue records are shared engine channels.
            # Their INFO IDs are still renumbered, but the original DIAL IDs
            # must stay available for normal greeting/hello/hit/idle selection.
            continue
        dial_map[key] = private_dial_id(old, used)

    source_info_ids = []
    seen: set[str] = set()
    for plugin in (core, patch):
        for record in plugin[1:]:
            if record['type'] == 'DialogueInfo' and record['id'] not in seen:
                source_info_ids.append(record['id'])
                seen.add(record['id'])
    used_info = set(master_infos)
    info_map: dict[str, str] = {}
    candidate = INFO_START
    for old in source_info_ids:
        while str(candidate) in used_info:
            candidate += 1
        info_map[old] = str(candidate)
        used_info.add(str(candidate))
        candidate += 1
    return dial_map, info_map


def replace_dialogue_calls(text: str, dial_map: dict[str, str]) -> tuple[str, list[str]]:
    """Repair only MWScript commands that accept a dialogue/journal ID."""
    replaced: list[str] = []
    for old, new in sorted(dial_map.items(), key=lambda item: len(item[0]), reverse=True):
        pattern = re.compile(
            r'(?i)(\b(?:journal|getjournalindex|addtopic|removetopic)\s+")' + re.escape(old) + r'(")'
        )
        text, count = pattern.subn(lambda match: match.group(1) + new + match.group(2), text)
        replaced.extend([old] * count)
    return text, replaced


def remap_bytecode(zstd: Zstd, encoded: str, keys: list[str], dial_map: dict[str, str]) -> tuple[str, int]:
    raw = zstd.decompress(encoded)
    changes = 0
    for old in sorted(set(keys), key=len, reverse=True):
        new = dial_map[old]
        raw, count = re.subn(
            rb'(?<![A-Za-z0-9_-])' + re.escape(old.encode('cp1252')) + rb'(?![A-Za-z0-9_-])',
            new.encode('cp1252'),
            raw,
            flags=re.IGNORECASE,
        )
        changes += count
    return zstd.compress(raw), changes


def migrate_plugin(plugin: list, dial_map: dict[str, str], info_map: dict[str, str], zstd: Zstd) -> dict[str, int]:
    stats = {
        'dialoguesRenamed': 0,
        'infosRenumbered': 0,
        'infoMasterLinksSevered': 0,
        'scriptSourceReferences': 0,
        'scriptBytecodeReferences': 0,
        'infoScriptReferences': 0,
    }
    for record in plugin[1:]:
        if record['type'] == 'Dialogue':
            mapped = dial_map.get(record['id'].lower())
            if mapped:
                record['id'] = mapped
                stats['dialoguesRenamed'] += 1
        elif record['type'] == 'DialogueInfo':
            record['id'] = info_map[record['id']]
            stats['infosRenumbered'] += 1
            for field in ('prev_id', 'next_id'):
                old = record.get(field, '')
                if not old:
                    continue
                if old in info_map:
                    record[field] = info_map[old]
                else:
                    record[field] = ''
                    stats['infoMasterLinksSevered'] += 1
            if record.get('script_text'):
                record['script_text'], changed = replace_dialogue_calls(record['script_text'], dial_map)
                stats['infoScriptReferences'] += len(changed)
        elif record['type'] == 'Script':
            record['text'], changed = replace_dialogue_calls(record.get('text', ''), dial_map)
            stats['scriptSourceReferences'] += len(changed)
            if changed:
                record['bytecode'], byte_changes = remap_bytecode(zstd, record['bytecode'], changed, dial_map)
                stats['scriptBytecodeReferences'] += byte_changes
    plugin[0]['num_objects'] = len(plugin) - 1
    return stats


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--core-input', type=Path, required=True)
    parser.add_argument('--patch-input', type=Path, required=True)
    parser.add_argument('--master', type=Path, action='append', required=True)
    parser.add_argument('--core-output', type=Path, required=True)
    parser.add_argument('--patch-output', type=Path, required=True)
    parser.add_argument('--map-output', type=Path, required=True)
    args = parser.parse_args()

    core = read_json(args.core_input)
    patch = read_json(args.patch_input)
    master_dials = master_records(args.master, 'Dialogue')
    master_infos = set(master_records(args.master, 'DialogueInfo'))
    dial_map, info_map = make_maps(core, patch, master_dials, master_infos)
    zstd = Zstd()
    core_stats = migrate_plugin(core, dial_map, info_map, zstd)
    patch_stats = migrate_plugin(patch, dial_map, info_map, zstd)

    output_dials = [record for plugin in (core, patch) for record in plugin[1:] if record['type'] == 'Dialogue']
    output_infos = {record['id'] for plugin in (core, patch) for record in plugin[1:] if record['type'] == 'DialogueInfo'}
    blocking_dials = [record for record in output_dials if record['id'].lower() in master_dials and record['dialogue_type'] not in SHARED_DIALOGUE_TYPES]
    if blocking_dials:
        names = ', '.join(sorted(record['id'] for record in blocking_dials[:10]))
        raise RuntimeError(f'A converted Starwind dialogue record still overrides a non-shared master dialogue ID: {names}')
    if output_infos.intersection(master_infos):
        raise RuntimeError('A converted Starwind INFO record still overrides a master INFO ID.')

    write_json(core, args.core_output)
    write_json(patch, args.patch_output)
    payload = {
        'dialogueIds': dial_map,
        'infoRecordCount': len(info_map),
        'infoIdRange': [min(info_map.values()), max(info_map.values())],
        'core': core_stats,
        'patch': patch_stats,
    }
    write_json(payload, args.map_output)
    print(json.dumps(payload, indent=2, sort_keys=True))


if __name__ == '__main__':
    main()
