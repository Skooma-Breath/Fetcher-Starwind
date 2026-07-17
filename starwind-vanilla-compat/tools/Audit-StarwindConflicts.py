"""Report every generated record whose TES3 record key still exists in a master."""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path


def read_json(path: Path):
    with path.open(encoding='utf-8-sig') as source:
        return json.load(source)


def record_key(record: dict):
    if 'id' in record:
        return f"id:{record['id'].lower()}"
    if record['type'] == 'Cell':
        if 'IS_INTERIOR' in record['data']['flags']:
            return f"interior:{record.get('name', '').lower()}"
        return f"exterior:{record['data']['grid'][0]}|{record['data']['grid'][1]}"
    if record['type'] == 'Landscape':
        return f"land:{record['grid'][0]}|{record['grid'][1]}"
    if record['type'] == 'PathGrid':
        return f"path:{record.get('cell', '').lower()}|{record['data']['grid'][0]}|{record['data']['grid'][1]}"
    return None


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--master', type=Path, action='append', required=True)
    parser.add_argument('--plugin', type=Path, action='append', required=True)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--fail-on-conflicts', action='store_true')
    parser.add_argument(
        '--allow-conflict',
        action='append',
        default=[],
        help='Intentional conflict formatted as RECORD_TYPE|RECORD_KEY.',
    )
    args = parser.parse_args()
    allowed = set()
    for value in args.allow_conflict:
        record_type, separator, key = value.partition('|')
        if not separator or not record_type or not key:
            raise SystemExit(f'Invalid --allow-conflict value: {value!r}')
        allowed.add((record_type, key))

    masters: dict[tuple[str, str], str] = {}
    for path in args.master:
        for record in read_json(path)[1:]:
            key = record_key(record)
            if key is not None:
                masters[(record['type'], key)] = path.stem
    conflicts = []
    for path in args.plugin:
        for record in read_json(path)[1:]:
            key = record_key(record)
            master = masters.get((record['type'], key)) if key is not None else None
            if master and record['type'] == 'Dialogue' and record.get('dialogue_type') in ('Greeting', 'Voice'):
                master = None
            if master and (record['type'], key) in allowed:
                master = None
            if master:
                conflicts.append({
                    'Plugin': path.stem,
                    'Master': master,
                    'RecordType': record['type'],
                    'RecordKey': key,
                })
    args.report.parent.mkdir(parents=True, exist_ok=True)
    with args.report.open('w', encoding='utf-8', newline='') as output:
        writer = csv.DictWriter(output, fieldnames=['Plugin', 'Master', 'RecordType', 'RecordKey'])
        writer.writeheader()
        writer.writerows(conflicts)
    print(f'Generated master-key conflicts: {len(conflicts)}')
    if args.fail_on_conflicts and conflicts:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
