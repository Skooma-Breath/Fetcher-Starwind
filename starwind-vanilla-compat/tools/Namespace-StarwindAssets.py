"""Copy changed Starwind visual assets into a private namespace.

Uses the installed Greatness7 Morrowind Blender add-on's NIF library directly.
That keeps the original geometry and only rewrites NiSourceTexture filenames;
Blender itself is not started and no scene conversion is involved.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import shutil
import struct
import sys
from pathlib import Path


ADDON_LIB = Path(r"C:\Users\REPTILE\AppData\Roaming\Blender Foundation\Blender\4.5\scripts\addons\io_scene_mw\lib")


def canonical(path: str) -> str:
    return path.replace('/', '\\').lstrip('\\').lower()


def private_path(path: str) -> str:
    return 'starwind_compat\\' + path.replace('/', '\\').lstrip('\\')


def copy_asset(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)

def copy_animation_companions(mesh_path: Path, destination: Path) -> list[tuple[Path, Path]]:
    copied: list[tuple[Path, Path]] = []
    companion_stem = 'x' + mesh_path.stem
    for candidate in mesh_path.parent.glob('*.kf'):
        if candidate.stem.lower() != companion_stem.lower():
            continue
        target = destination.parent / ('x' + destination.stem + candidate.suffix.lower())
        copy_asset(candidate, target)
        copied.append((candidate, target))
    return copied


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def replace_length_prefixed_strings(source: bytes, replacements: list[dict[str, object]]) -> bytes:
    result = source
    for replacement in replacements:
        old_value = str(replacement['from'])
        new_value = str(replacement['to'])
        old_bytes = old_value.encode('ascii')
        new_bytes = new_value.encode('ascii')
        pattern = struct.pack('<I', len(old_bytes)) + old_bytes
        updated = struct.pack('<I', len(new_bytes)) + new_bytes
        occurrences = result.count(pattern)
        if occurrences != int(replacement['occurrences']):
            raise RuntimeError(
                f'Expected {replacement["occurrences"]} occurrence(s) of {old_value!r}, found {occurrences}.'
            )
        result = result.replace(pattern, updated)
    return result


def load_changed_assets(report: Path) -> tuple[dict[str, str], dict[str, str], set[str]]:
    texture_map: dict[str, str] = {}
    icon_map: dict[str, str] = {}
    changed_meshes: set[str] = set()
    with report.open(newline='', encoding='utf-8-sig') as input_file:
        for row in csv.DictReader(input_file):
            if row['Content'] != 'Different':
                continue
            root, _, rest = row['RelativePath'].partition('\\')
            root = root.lower()
            extension = row['Extension'].lower()
            if root == 'textures' and extension == '.dds':
                texture_map[canonical(f"textures\\{rest}")] = canonical(f"textures\\{private_path(rest)}")
            elif root == 'icons' and extension == '.dds':
                icon_map[canonical(rest)] = canonical(private_path(rest))
            elif root == 'meshes' and extension == '.nif':
                changed_meshes.add(canonical(rest))
    return texture_map, icon_map, changed_meshes


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--source-data', type=Path, required=True)
    parser.add_argument('--official-data', type=Path, required=False)
    parser.add_argument('--comparison', type=Path, required=True)
    parser.add_argument('--output-data', type=Path, required=True)
    parser.add_argument('--mappings', type=Path, required=True)
    args = parser.parse_args()

    if not ADDON_LIB.is_dir():
        raise FileNotFoundError(f'Greatness7 NIF library was not found: {ADDON_LIB}')
    sys.path.insert(0, str(ADDON_LIB))
    from es3 import nif  # pylint: disable=import-outside-toplevel

    texture_map, icon_map, changed_meshes = load_changed_assets(args.comparison)
    if not texture_map or not icon_map or not changed_meshes:
        raise RuntimeError('Comparison report did not contain all expected changed texture, icon, and NIF groups.')

    copied_textures = 0
    for old_path, new_path in texture_map.items():
        source = args.source_data / old_path
        destination = args.output_data / new_path
        if not source.is_file():
            raise FileNotFoundError(f'Missing Starwind texture: {source}')
        copy_asset(source, destination)
        copied_textures += 1

    copied_icons = 0
    for old_path, new_path in icon_map.items():
        source = args.source_data / 'Icons' / old_path
        destination = args.output_data / 'Icons' / new_path
        if not source.is_file():
            raise FileNotFoundError(f'Missing Starwind icon: {source}')
        copy_asset(source, destination)
        copied_icons += 1

    mesh_map: dict[str, str] = {}
    rewritten_meshes = 0
    copied_animation_companions = 0
    scanned_meshes = 0
    local_morrowind_rewritten_meshes: list[dict[str, object]] = []
    local_morrowind_copied_assets: list[dict[str, str]] = []
    official_meshes = args.official_data / 'Meshes' if args.official_data else None
    if official_meshes is not None and not official_meshes.is_dir():
        raise FileNotFoundError(f'Official Meshes directory was not found: {official_meshes}')

    for mesh_path in sorted((args.source_data / 'Meshes').rglob('*.nif')):
        scanned_meshes += 1
        relative = mesh_path.relative_to(args.source_data / 'Meshes')
        old_mesh_path = canonical(str(relative))
        stream = nif.NiStream()
        try:
            stream.load(mesh_path)
        except Exception as error:  # Do not leave an unknown potentially-colliding model unhandled.
            raise RuntimeError(f'Unable to read NIF {mesh_path}: {error}') from error

        replacement_counts: dict[tuple[str, str], int] = {}
        for source_texture in stream.objects_of_type(nif.NiSourceTexture):
            original_texture_path = source_texture.filename
            old_texture_path = canonical(original_texture_path)
            candidate_texture_paths = [old_texture_path]
            if not old_texture_path.startswith('textures\\'):
                candidate_texture_paths.append('textures\\' + old_texture_path)
            stem = old_texture_path.rsplit('.', 1)[0]
            if stem != old_texture_path:
                candidate_texture_paths.append(stem + '.dds')
                if not stem.startswith('textures\\'):
                    candidate_texture_paths.append('textures\\' + stem + '.dds')
            new_texture_path = next((texture_map[candidate] for candidate in candidate_texture_paths if candidate in texture_map), None)
            if new_texture_path:
                source_texture.filename = new_texture_path
                key = (original_texture_path, new_texture_path)
                replacement_counts[key] = replacement_counts.get(key, 0) + 1

        if old_mesh_path in changed_meshes or replacement_counts:
            new_mesh_path = private_path(str(relative))
            destination = args.output_data / 'Meshes' / new_mesh_path
            destination.parent.mkdir(parents=True, exist_ok=True)
            official_counterpart = official_meshes / relative if official_meshes is not None else None
            source_is_official = (
                old_mesh_path not in changed_meshes
                and official_counterpart is not None
                and official_counterpart.is_file()
                and sha256(mesh_path) == sha256(official_counterpart)
            )
            replacements = [
                {'from': old_value, 'to': new_value, 'occurrences': occurrences}
                for (old_value, new_value), occurrences in replacement_counts.items()
            ]
            if source_is_official:
                destination.write_bytes(replace_length_prefixed_strings(official_counterpart.read_bytes(), replacements))
                local_morrowind_rewritten_meshes.append({
                    'sourcePath': official_counterpart.relative_to(args.official_data).as_posix(),
                    'destinationPath': destination.relative_to(args.output_data).as_posix(),
                    'sourceSha256': sha256(official_counterpart),
                    'resultSha256': sha256(destination),
                    'replacements': replacements,
                })
            else:
                stream.save(destination)

            companion_pairs = copy_animation_companions(mesh_path, destination)
            copied_animation_companions += len(companion_pairs)
            if args.official_data:
                for source_companion, destination_companion in companion_pairs:
                    source_relative = source_companion.relative_to(args.source_data)
                    official_companion = args.official_data / source_relative
                    if official_companion.is_file() and sha256(source_companion) == sha256(official_companion):
                        local_morrowind_copied_assets.append({
                            'sourcePath': source_relative.as_posix(),
                            'destinationPath': destination_companion.relative_to(args.output_data).as_posix(),
                            'sha256': sha256(destination_companion),
                        })

            mesh_map[old_mesh_path] = canonical(new_mesh_path)
            rewritten_meshes += 1

    texture_only_official_meshes = 0
    if official_meshes is not None:
        for mesh_path in sorted(official_meshes.rglob('*.nif')):
            scanned_meshes += 1
            relative = mesh_path.relative_to(official_meshes)
            old_mesh_path = canonical(str(relative))
            if old_mesh_path in mesh_map:
                continue
            stream = nif.NiStream()
            try:
                stream.load(mesh_path)
            except Exception as error:
                raise RuntimeError(f'Unable to read official NIF {mesh_path}: {error}') from error

            replacement_counts: dict[tuple[str, str], int] = {}
            for source_texture in stream.objects_of_type(nif.NiSourceTexture):
                original_texture_path = source_texture.filename
                old_texture_path = canonical(original_texture_path)
                candidate_texture_paths = [old_texture_path]
                if not old_texture_path.startswith('textures\\'):
                    candidate_texture_paths.append('textures\\' + old_texture_path)
                stem = old_texture_path.rsplit('.', 1)[0]
                if stem != old_texture_path:
                    candidate_texture_paths.append(stem + '.dds')
                    if not stem.startswith('textures\\'):
                        candidate_texture_paths.append('textures\\' + stem + '.dds')
                new_texture_path = next((texture_map[candidate] for candidate in candidate_texture_paths if candidate in texture_map), None)
                if new_texture_path:
                    source_texture.filename = new_texture_path
                    key = (original_texture_path, new_texture_path)
                    replacement_counts[key] = replacement_counts.get(key, 0) + 1

            if replacement_counts:
                new_mesh_path = private_path(str(relative))
                destination = args.output_data / 'Meshes' / new_mesh_path
                destination.parent.mkdir(parents=True, exist_ok=True)
                replacements = [
                    {'from': old_value, 'to': new_value, 'occurrences': occurrences}
                    for (old_value, new_value), occurrences in replacement_counts.items()
                ]
                destination.write_bytes(replace_length_prefixed_strings(mesh_path.read_bytes(), replacements))

                verification_stream = nif.NiStream()
                verification_stream.load(destination)
                expected_textures = [item.filename for item in stream.objects_of_type(nif.NiSourceTexture)]
                actual_textures = [item.filename for item in verification_stream.objects_of_type(nif.NiSourceTexture)]
                if actual_textures != expected_textures:
                    raise RuntimeError(f'Length-prefixed texture rewrite verification failed for {destination}')

                companion_pairs = copy_animation_companions(mesh_path, destination)
                copied_animation_companions += len(companion_pairs)
                for source_companion, destination_companion in companion_pairs:
                    local_morrowind_copied_assets.append({
                        'sourcePath': source_companion.relative_to(args.official_data).as_posix(),
                        'destinationPath': destination_companion.relative_to(args.output_data).as_posix(),
                        'sha256': sha256(destination_companion),
                    })

                local_morrowind_rewritten_meshes.append({
                    'sourcePath': mesh_path.relative_to(args.official_data).as_posix(),
                    'destinationPath': destination.relative_to(args.output_data).as_posix(),
                    'sourceSha256': sha256(mesh_path),
                    'resultSha256': sha256(destination),
                    'replacements': replacements,
                })
                mesh_map[old_mesh_path] = canonical(new_mesh_path)
                rewritten_meshes += 1
                texture_only_official_meshes += 1
    missing_collision_meshes = changed_meshes.difference(mesh_map)
    if missing_collision_meshes:
        raise RuntimeError('Some changed NIFs were not isolated: ' + ', '.join(sorted(missing_collision_meshes)))

    payload = {
        'mesh': mesh_map,
        'icon': icon_map,
        'texture': texture_map,
        'localMorrowind': {
            'rewrittenMeshes': local_morrowind_rewritten_meshes,
            'copiedAssets': local_morrowind_copied_assets,
        },
        'summary': {
            'changedTexturesCopied': copied_textures,
            'changedIconsCopied': copied_icons,
            'meshesScanned': scanned_meshes,
            'meshesNamespaced': rewritten_meshes,
            'textureOnlyOfficialMeshesNamespaced': texture_only_official_meshes,
            'animationCompanionsCopied': copied_animation_companions,
        },
    }
    args.mappings.parent.mkdir(parents=True, exist_ok=True)
    args.mappings.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding='utf-8')
    print(json.dumps(payload['summary'], indent=2))


if __name__ == '__main__':
    main()
