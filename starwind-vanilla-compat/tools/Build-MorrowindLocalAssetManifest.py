"""Build the installer recipe for official Morrowind-derived compatibility files.

The release package must not redistribute those files.  Instead, this manifest
records where each file comes from in the tester's own Morrowind installation,
the expected hashes, and the small texture-path edits needed for official NIFs
that Starwind uses with private textures.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import subprocess
from pathlib import Path
from typing import Any


ARCHIVE_PRIORITY = ('Morrowind.bsa', 'Tribunal.bsa', 'Bloodmoon.bsa')
REQUIRED_CREATURE_COMPANIONS = (
    'xancestorghost.kf', 'xashslave.kf', 'xbyagram.kf', 'xcavemudcrab.kf',
    'xcliffracer.kf', 'xdurzog.kf', 'xduskyalit.kf', 'xfabricant.kf',
    'xfabricant_hulking.kf', 'xfabricant_imperfect.kf', 'xfabricant_imperfect.nif',
    'xfrostgiant.kf', 'xgreatbonewalker.kf', 'xguar.kf', 'xice troll.kf',
    'xkwama forager.kf', 'xkwama warior.kf', 'xleastkagouti.kf',
    'xlordvivec.kf', 'xminescrib.kf', 'xnixhound.kf', 'xscamp_fetch.kf',
)
OFFICIAL_LOOSE_PATHS = (
    'Sound/Fx/item/bookopen.wav',
    'Sound/Fx/item/bookclose.wav',
    'Sound/Fx/item/bookpag1.wav',
    'Sound/Fx/item/bookpag2.wav',
    'Sound/Fx/menu click.wav',
    'Sound/Fx/inter/levelUP.wav',
    'Sound/Fx/item/bowAWAY.wav',
    'Sound/Fx/item/bowOUT.wav',
    'Sound/Fx/item/bowPULL.wav',
    'Sound/Fx/item/bowSHOOT.wav',
    'Sound/Fx/item/cbowAWAY.wav',
    'Sound/Fx/item/cbowOUT.wav',
    'Sound/Fx/item/cbowPULL.wav',
    'Sound/Fx/item/cbowSHOOT.wav',
    'Sound/Fx/item/cbowshoot2.wav',
)


def canonical(path: str) -> str:
    return path.replace('\\', '/').lstrip('/').lower()


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def list_archive(bsatool: Path, archive: Path) -> dict[str, str]:
    result = subprocess.run(
        [str(bsatool), 'list', str(archive)],
        check=True,
        capture_output=True,
        text=True,
        encoding='utf-8',
        errors='replace',
    )
    entries: dict[str, str] = {}
    for line in result.stdout.splitlines():
        relative = line.strip().replace('\\', '/')
        if relative:
            entries[canonical(relative)] = relative
    return entries


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--overlay', type=Path, required=True)
    parser.add_argument('--comparison', type=Path, required=True)
    parser.add_argument('--namespace-map', type=Path, required=True)
    parser.add_argument('--official-data', type=Path, required=True)
    parser.add_argument('--official-loose-data', type=Path, required=False)
    parser.add_argument('--bsatool', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()

    for required in (args.overlay, args.comparison, args.namespace_map, args.official_data, args.bsatool):
        if not required.exists():
            raise FileNotFoundError(f'Required input was not found: {required}')

    archive_entries: dict[str, dict[str, str]] = {}
    winning_archive: dict[str, tuple[str, str]] = {}
    for archive_name in ARCHIVE_PRIORITY:
        archive_path = args.official_data / archive_name
        if not archive_path.is_file():
            raise FileNotFoundError(f'Official archive was not found: {archive_path}')
        entries = list_archive(args.bsatool, archive_path)
        archive_entries[archive_name] = entries
        for key, exact_path in entries.items():
            winning_archive[key] = (archive_name, exact_path)

    loose_roots = [root for root in (args.official_loose_data, args.official_data) if root and root.is_dir()]
    files_by_destination: dict[str, dict[str, Any]] = {}

    def find_loose(source_path: str, expected_hash: str) -> Path | None:
        for root in loose_roots:
            candidate = root / Path(source_path)
            if candidate.is_file() and sha256(candidate) == expected_hash:
                return candidate
        return None

    def source_descriptor(source_path: str, expected_hash: str, preferred_archive: str | None = None) -> dict[str, Any]:
        source_key = canonical(source_path)
        loose = find_loose(source_path, expected_hash)
        archive_name: str | None = None
        archive_path: str | None = None
        if preferred_archive:
            exact = archive_entries.get(preferred_archive, {}).get(source_key)
            if exact:
                archive_name = preferred_archive
                archive_path = exact
        elif source_key in winning_archive:
            archive_name, archive_path = winning_archive[source_key]
        if loose is None and archive_name is None:
            raise FileNotFoundError(
                f'Official source is neither available loose nor present in an official BSA: {source_path}'
            )
        return {
            'path': source_path.replace('\\', '/'),
            'sha256': expected_hash,
            'archive': archive_name,
            'archivePath': archive_path,
        }

    def add_copy(
        source_path: str,
        destination_path: str,
        preferred_archive: str | None = None,
        replace_existing: bool = False,
    ) -> None:
        destination_path = destination_path.replace('\\', '/')
        destination = args.overlay / Path(destination_path)
        if not destination.is_file():
            raise FileNotFoundError(f'Expected official-derived overlay file is missing: {destination}')
        result_hash = sha256(destination)
        entry = {
            'operation': 'copy',
            'source': source_descriptor(source_path, result_hash, preferred_archive),
            'destinationPath': destination_path,
            'resultSha256': result_hash,
        }
        key = canonical(destination_path)
        existing = files_by_destination.get(key)
        if existing:
            same_source = canonical(existing['source']['path']) == canonical(entry['source']['path'])
            same_result = existing['resultSha256'] == entry['resultSha256']
            if not same_source or not same_result:
                raise RuntimeError(f'Conflicting local-asset recipes for {destination_path}')
            if replace_existing:
                files_by_destination[key] = entry
            return
        files_by_destination[key] = entry

    with args.comparison.open(newline='', encoding='utf-8-sig') as input_file:
        for row in csv.DictReader(input_file):
            if row['Content'] == 'Different':
                add_copy(row['RelativePath'], row['RelativePath'], row['OfficialArchive'])

    for texture in sorted((args.overlay / 'Textures').glob('tx_menubook*.dds')):
        add_copy(
            texture.relative_to(args.overlay).as_posix(),
            texture.relative_to(args.overlay).as_posix(),
            'Morrowind.bsa',
            replace_existing=True,
        )

    for relative in OFFICIAL_LOOSE_PATHS:
        add_copy(relative, relative)

    splash_root = args.overlay / 'Splash'
    splashes = sorted(splash_root.glob('*.tga'))
    if len(splashes) != 11:
        raise RuntimeError(f'Expected 11 official splash screens in {splash_root}, found {len(splashes)}.')
    for splash in splashes:
        relative = splash.relative_to(args.overlay).as_posix()
        add_copy(relative, relative)

    for companion_name in REQUIRED_CREATURE_COMPANIONS:
        source_path = f'Meshes/r/{companion_name}'
        destination_path = f'Meshes/starwind_compat/r/{companion_name}'
        destination = args.overlay / Path(destination_path)
        if not destination.is_file():
            raise FileNotFoundError(f'Required creature companion is missing: {destination}')
        if find_loose(source_path, sha256(destination)) is not None:
            add_copy(source_path, destination_path)
        else:
            print(f'Keeping modified non-vanilla creature companion in payload: {destination_path}')

    namespace_map = json.loads(args.namespace_map.read_text(encoding='utf-8'))
    local_morrowind = namespace_map.get('localMorrowind')
    if not local_morrowind:
        raise RuntimeError('The namespace map does not contain localMorrowind reconstruction data.')

    for copied in local_morrowind.get('copiedAssets', []):
        add_copy(copied['sourcePath'], copied['destinationPath'])

    for rewritten in local_morrowind.get('rewrittenMeshes', []):
        destination_path = rewritten['destinationPath'].replace('\\', '/')
        destination = args.overlay / Path(destination_path)
        if not destination.is_file():
            raise FileNotFoundError(f'Rewritten official NIF is missing: {destination}')
        result_hash = sha256(destination)
        if result_hash != rewritten['resultSha256']:
            raise RuntimeError(f'Rewritten NIF hash mismatch in namespace map: {destination_path}')
        entry = {
            'operation': 'rewriteNifTexturePaths',
            'source': source_descriptor(rewritten['sourcePath'], rewritten['sourceSha256']),
            'destinationPath': destination_path,
            'resultSha256': result_hash,
            'replacements': rewritten['replacements'],
        }
        key = canonical(destination_path)
        if key in files_by_destination:
            raise RuntimeError(f'Duplicate local-asset destination: {destination_path}')
        files_by_destination[key] = entry

    files = sorted(files_by_destination.values(), key=lambda item: canonical(item['destinationPath']))
    operation_counts: dict[str, int] = {}
    total_bytes = 0
    for item in files:
        operation_counts[item['operation']] = operation_counts.get(item['operation'], 0) + 1
        total_bytes += (args.overlay / Path(item['destinationPath'])).stat().st_size

    payload = {
        'schemaVersion': 1,
        'manifestId': 'fetcher-starwind-local-morrowind-assets',
        'files': files,
        'summary': {
            'fileCount': len(files),
            'unpackagedBytes': total_bytes,
            'operationCounts': operation_counts,
        },
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding='utf-8')
    print(json.dumps(payload['summary'], indent=2, sort_keys=True))


if __name__ == '__main__':
    main()
