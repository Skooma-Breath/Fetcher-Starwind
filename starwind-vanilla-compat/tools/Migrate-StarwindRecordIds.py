"""Namespace every remaining Starwind record that has an official master ID.

All generated identifiers retain the exact CP1252 byte length of the original
identifier.  This permits direct, safe replacements in compressed MWScript
bytecode as well as in ordinary record links, without relying on runtime
recompilation.
"""

from __future__ import annotations

import argparse
import base64
import ctypes
import json
import re
from pathlib import Path


ZSTD_DLL = Path(r"C:\Program Files\OpenMW 0.50.0\zstd.dll")
ALPHABET = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ'


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


def base36(value: int, width: int) -> str:
    result = ''
    for _ in range(width):
        result = ALPHABET[value % len(ALPHABET)] + result
        value //= len(ALPHABET)
    return result


def private_id(old: str, used: set[str]) -> str:
    width = len(old.encode('cp1252'))
    if width < 3:
        raise RuntimeError(f'Record ID is too short to isolate safely: {old!r}')
    prefix = 'SW_' if width >= 4 else 'S'
    suffix_width = width - len(prefix)
    candidate = (prefix + old)[:width]
    if candidate.lower() not in used:
        used.add(candidate.lower())
        return candidate
    for sequence in range(len(ALPHABET) ** suffix_width):
        candidate = prefix + base36(sequence, suffix_width)
        if candidate.lower() not in used:
            used.add(candidate.lower())
            return candidate
    raise RuntimeError(f'No unique private ID is available for {old!r}')


def master_ids(master_paths: list[Path]) -> set[tuple[str, str]]:
    return {
        (record['type'], record['id'].lower())
        for path in master_paths
        for record in read_json(path)[1:]
        if 'id' in record
    }


def build_id_map(core: list, patch: list, masters: set[tuple[str, str]]) -> tuple[dict[str, str], dict[str, int]]:
    records = core[1:] + patch[1:]
    collisions: dict[str, set[str]] = {}
    source_ids: set[str] = set()
    spellings: dict[str, str] = {}
    for record in records:
        if 'id' not in record or record['type'] in ('Dialogue', 'DialogueInfo'):
            continue
        key = record['id'].lower()
        source_ids.add(key)
        spellings.setdefault(key, record['id'])
        if (record['type'], key) in masters:
            collisions.setdefault(key, set()).add(record['type'])
    master_id_values = {key for _, key in masters}
    used = master_id_values | (source_ids - set(collisions))
    mapping: dict[str, str] = {}
    for key in sorted(collisions):
        mapping[key] = private_id(spellings[key], used)
    summary: dict[str, int] = {}
    for types in collisions.values():
        for record_type in types:
            summary[record_type] = summary.get(record_type, 0) + 1
    return mapping, summary


def remap_values(value, mapping: dict[str, str], stats: dict[str, int], parent_key: str | None = None):
    if isinstance(value, str):
        mapped = mapping.get(value.lower())
        if mapped is not None:
            stats['recordLinksRemapped'] += 1
            return mapped
        return value
    if isinstance(value, list):
        return [remap_values(item, mapping, stats, parent_key) for item in value]
    if isinstance(value, dict):
        return {
            # These are display strings, file paths, or TES3 enum values (for
            # example an enchantment effect named "Shield"), not record links.
            # Replacing them by a private record ID would corrupt the schema.
            key: value if key in ('text', 'script_text', 'result', 'name', 'model', 'icon', 'sound_path', 'effect', 'effects', 'magic_effect', 'attribute', 'attributes', 'skill', 'skills', 'dialogue_type', 'flags', 'file_type', 'author', 'description', 'type') or key.endswith('_type') else remap_values(value, mapping, stats, key)
            for key, value in value.items()
        }
    return value


def replace_code_ids(text: str, mapping: dict[str, str]) -> tuple[str, list[str]]:
    """Replace record IDs in code, without rewriting words inside display strings."""
    changed: list[str] = []
    output = []
    for line in text.splitlines(keepends=True):
        code, marker, comment = line.partition(';')
        pieces = re.split(r'("(?:[^"]|"")*")', code)
        for index, piece in enumerate(pieces):
            if index % 2:
                key = piece[1:-1].lower()
                if key in mapping:
                    pieces[index] = f'"{mapping[key]}"'
                    changed.append(key)
                continue
            for old, new in sorted(mapping.items(), key=lambda item: len(item[0]), reverse=True):
                pattern = re.compile(r'(?i)(?<![A-Za-z0-9_-])' + re.escape(old) + r'(?![A-Za-z0-9_-])')
                pieces[index], count = pattern.subn(new, pieces[index])
                changed.extend([old] * count)
        output.append(''.join(pieces) + marker + comment)
    return ''.join(output), changed


def remap_bytecode(zstd: Zstd, encoded: str, keys: list[str], mapping: dict[str, str]) -> tuple[str, int]:
    raw = zstd.decompress(encoded)
    changes = 0
    for old in sorted(set(keys), key=len, reverse=True):
        new = mapping[old]
        old_bytes, new_bytes = old.encode('cp1252'), new.encode('cp1252')
        if len(old_bytes) != len(new_bytes):
            raise RuntimeError(f'Unsafe bytecode replacement length for {old!r}')
        raw, count = re.subn(
            rb'(?<![A-Za-z0-9_-])' + re.escape(old_bytes) + rb'(?![A-Za-z0-9_-])',
            new_bytes,
            raw,
            flags=re.IGNORECASE,
        )
        changes += count
    return zstd.compress(raw), changes


def migrate_plugin(plugin: list, mapping: dict[str, str], zstd: Zstd) -> dict[str, int]:
    stats = {'recordLinksRemapped': 0, 'scriptSourceReferences': 0, 'scriptBytecodeReferences': 0, 'infoScriptReferences': 0}
    for index, record in enumerate(plugin[1:], start=1):
        record = remap_values(record, mapping, stats)
        if record['type'] == 'Script':
            record['text'], changed = replace_code_ids(record.get('text', ''), mapping)
            stats['scriptSourceReferences'] += len(changed)
            if changed:
                record['bytecode'], byte_changes = remap_bytecode(zstd, record['bytecode'], changed, mapping)
                stats['scriptBytecodeReferences'] += byte_changes
        elif record['type'] == 'DialogueInfo':
            for field in ('script_text', 'result'):
                if record.get(field):
                    record[field], changed = replace_code_ids(record[field], mapping)
                    stats['infoScriptReferences'] += len(changed)
        plugin[index] = record
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

    core, patch = read_json(args.core_input), read_json(args.patch_input)
    mapping, summary = build_id_map(core, patch, master_ids(args.master))
    zstd = Zstd()
    core_stats = migrate_plugin(core, mapping, zstd)
    patch_stats = migrate_plugin(patch, mapping, zstd)
    payload = {'recordIds': mapping, 'recordTypes': summary, 'core': core_stats, 'patch': patch_stats}
    write_json(core, args.core_output)
    write_json(patch, args.patch_output)
    write_json(payload, args.map_output)
    print(json.dumps(payload, indent=2, sort_keys=True))


if __name__ == '__main__':
    main()
