"""Isolate master-script records while keeping compiled MWScript valid."""

from __future__ import annotations

import argparse
import base64
import csv
import ctypes
import json
import re
from pathlib import Path


ZSTD_DLL = Path(r"C:\Program Files\OpenMW 0.50.0\zstd.dll")
ALPHABET = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ'


class Zstd:
    def __init__(self) -> None:
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

    def check(self, result: int) -> int:
        if self.lib.ZSTD_isError(result):
            raise RuntimeError(self.lib.ZSTD_getErrorName(result).decode('ascii'))
        return result

    def decompress(self, encoded: str) -> bytes:
        source = base64.b64decode(encoded)
        source_buffer = ctypes.create_string_buffer(source)
        size = self.lib.ZSTD_getFrameContentSize(source_buffer, len(source))
        if size >= (1 << 64) - 2:
            size = self.lib.ZSTD_decompressBound(source_buffer, len(source))
        output = ctypes.create_string_buffer(size)
        result = self.check(self.lib.ZSTD_decompress(output, size, source_buffer, len(source)))
        return output.raw[:result]

    def compress(self, raw: bytes) -> str:
        source = ctypes.create_string_buffer(raw)
        capacity = self.lib.ZSTD_compressBound(len(raw))
        output = ctypes.create_string_buffer(capacity)
        result = self.check(self.lib.ZSTD_compress(output, capacity, source, len(raw), 3))
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


def private_script_id(old: str, used: set[str]) -> str:
    width = len(old.encode('cp1252'))
    if width < 3:
        raise RuntimeError(f'Script ID is too short to isolate safely: {old!r}')
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
    raise RuntimeError(f'No private same-length Script ID is available for {old!r}')


def report_ids(reports: Path) -> tuple[set[str], set[str], set[str]]:
    values = {'Script': set(), 'GlobalVariable': set(), 'StartScript': set()}
    for report_name in ('overridden-records.csv', 'patch-overridden-records.csv'):
        with (reports / report_name).open(encoding='utf-8-sig', newline='') as source:
            for row in csv.DictReader(source):
                if row['RecordType'] in values:
                    values[row['RecordType']].add(row['Id'].lower())
    return values['Script'], values['GlobalVariable'], values['StartScript']


def replace_code_ids(text: str, mapping: dict[str, str]) -> tuple[str, list[str]]:
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
            raise RuntimeError(f'Unsafe bytecode replacement for Script ID {old!r}')
        raw, count = re.subn(
            rb'(?<![A-Za-z0-9_-])' + re.escape(old_bytes) + rb'(?![A-Za-z0-9_-])',
            new_bytes,
            raw,
            flags=re.IGNORECASE,
        )
        changes += count
    return zstd.compress(raw), changes


def remap_script_links(value, mapping: dict[str, str], stats: dict[str, int]):
    if isinstance(value, list):
        return [remap_script_links(item, mapping, stats) for item in value]
    if isinstance(value, dict):
        result = {}
        for key, item in value.items():
            if key == 'script' and isinstance(item, str) and item.lower() in mapping:
                result[key] = mapping[item.lower()]
                stats['scriptLinksRemapped'] += 1
            else:
                result[key] = remap_script_links(item, mapping, stats)
        return result
    return value


def code_has_identifier(text: str, identifiers: set[str]) -> list[str]:
    found = []
    for line in text.splitlines():
        code = line.partition(';')[0]
        code = re.sub(r'"(?:[^"]|"")*"', '', code)
        for identifier in identifiers:
            if re.search(r'(?i)(?<![A-Za-z0-9_-])' + re.escape(identifier) + r'(?![A-Za-z0-9_-])', code):
                found.append(identifier)
    return found


def migrate_plugin(plugin: list, script_map: dict[str, str], global_map: dict[str, str], start_ids: set[str], zstd: Zstd) -> dict[str, int]:
    code_map = script_map | global_map
    stats = {'scriptsRenamed': 0, 'globalsRenamed': 0, 'scriptLinksRemapped': 0, 'sourceReferences': 0, 'bytecodeReferences': 0, 'infoScriptReferences': 0, 'foreignStartScriptsRemoved': 0}
    output = [plugin[0]]
    for source_record in plugin[1:]:
        if source_record['type'] == 'StartScript' and source_record['id'].lower() in start_ids:
            stats['foreignStartScriptsRemoved'] += 1
            continue
        record = remap_script_links(source_record, script_map, stats)
        if record['type'] == 'Script':
            old_id = record['id'].lower()
            if old_id in script_map:
                record['id'] = script_map[old_id]
                stats['scriptsRenamed'] += 1
            record['text'], changed = replace_code_ids(record.get('text', ''), code_map)
            stats['sourceReferences'] += len(changed)
            if changed:
                record['bytecode'], count = remap_bytecode(zstd, record['bytecode'], changed, code_map)
                stats['bytecodeReferences'] += count
        elif record['type'] == 'GlobalVariable' and record['id'].lower() in global_map:
            record['id'] = global_map[record['id'].lower()]
            stats['globalsRenamed'] += 1
        elif record['type'] == 'DialogueInfo':
            for field in ('script_text', 'result'):
                if record.get(field):
                    record[field], changed = replace_code_ids(record[field], code_map)
                    stats['infoScriptReferences'] += len(changed)
        output.append(record)
    output[0]['num_objects'] = len(output) - 1
    plugin[:] = output
    return stats


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--core-input', type=Path, required=True)
    parser.add_argument('--patch-input', type=Path, required=True)
    parser.add_argument('--reports', type=Path, required=True)
    parser.add_argument('--core-output', type=Path, required=True)
    parser.add_argument('--patch-output', type=Path, required=True)
    parser.add_argument('--map-output', type=Path, required=True)
    args = parser.parse_args()

    core, patch = read_json(args.core_input), read_json(args.patch_input)
    reported_scripts, reported_globals, start_ids = report_ids(args.reports)
    script_records = [record for plugin in (core, patch) for record in plugin[1:] if record['type'] == 'Script']
    global_records = [record for plugin in (core, patch) for record in plugin[1:] if record['type'] == 'GlobalVariable']
    spellings = {record['id'].lower(): record['id'] for record in script_records}
    if not reported_scripts.issubset(spellings):
        missing = sorted(reported_scripts - set(spellings))
        raise RuntimeError(f'Expected overridden Script records are missing: {missing!r}')
    global_spellings = {record['id'].lower(): record['id'] for record in global_records}
    if not reported_globals.issubset(global_spellings):
        missing = sorted(reported_globals - set(global_spellings))
        raise RuntimeError(f'Expected overridden GlobalVariable records are missing: {missing!r}')
    used = (set(spellings) - reported_scripts) | (set(global_spellings) - reported_globals)
    script_map = {old: private_script_id(spellings[old], used) for old in sorted(reported_scripts)}
    global_map = {old: private_script_id(global_spellings[old], used) for old in sorted(reported_globals)}
    for old, new in script_map.items():
        if len(old.encode('cp1252')) != len(new.encode('cp1252')):
            raise RuntimeError(f'Non-equal Script byte lengths for {old!r}')

    zstd = Zstd()
    core_stats = migrate_plugin(core, script_map, global_map, start_ids, zstd)
    patch_stats = migrate_plugin(patch, script_map, global_map, start_ids, zstd)
    remaining_scripts = [record['id'] for plugin in (core, patch) for record in plugin[1:] if record['type'] == 'Script' and record['id'].lower() in reported_scripts]
    if remaining_scripts:
        raise RuntimeError(f'Official Script records remain: {remaining_scripts!r}')
    payload = {'scriptIds': script_map, 'globalIds': global_map, 'removedStartScriptIds': sorted(start_ids), 'core': core_stats, 'patch': patch_stats}
    write_json(core, args.core_output)
    write_json(patch, args.patch_output)
    write_json(payload, args.map_output)
    print(json.dumps(payload, indent=2, sort_keys=True))


if __name__ == '__main__':
    main()
