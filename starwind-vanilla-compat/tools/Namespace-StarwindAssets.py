"""Copy changed Starwind visual assets into a private namespace.

Uses the installed Greatness7 Morrowind Blender add-on's NIF library directly.
That keeps the original geometry and only rewrites NiSourceTexture filenames;
Blender itself is not started and no scene conversion is involved.
"""

from __future__ import annotations

import argparse
import csv
import json
import shutil
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

def copy_animation_companions(mesh_path: Path, destination: Path) -> int:
    copied = 0
    companion_stem = 'x' + mesh_path.stem
    for candidate in mesh_path.parent.glob('*.kf'):
        if candidate.stem.lower() != companion_stem.lower():
            continue
        target = destination.parent / ('x' + destination.stem + candidate.suffix.lower())
        copy_asset(candidate, target)
        copied += 1
    return copied


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
    for mesh_path in sorted((args.source_data / 'Meshes').rglob('*.nif')):
        scanned_meshes += 1
        relative = mesh_path.relative_to(args.source_data / 'Meshes')
        old_mesh_path = canonical(str(relative))
        stream = nif.NiStream()
        try:
            stream.load(mesh_path)
        except Exception as error:  # Do not leave an unknown potentially-colliding model unhandled.
            raise RuntimeError(f'Unable to read NIF {mesh_path}: {error}') from error

        texture_rewrites = 0
        for source_texture in stream.objects_of_type(nif.NiSourceTexture):
            old_texture_path = canonical(source_texture.filename)
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
                texture_rewrites += 1

        if old_mesh_path in changed_meshes or texture_rewrites:
            new_mesh_path = private_path(str(relative))
            destination = args.output_data / 'Meshes' / new_mesh_path
            destination.parent.mkdir(parents=True, exist_ok=True)
            stream.save(destination)
            copied_animation_companions += copy_animation_companions(mesh_path, destination)
            mesh_map[old_mesh_path] = canonical(new_mesh_path)
            rewritten_meshes += 1


    texture_only_official_meshes = 0
    if args.official_data:
        official_meshes = args.official_data / 'Meshes'
        if not official_meshes.is_dir():
            raise FileNotFoundError(f'Official Meshes directory was not found: {official_meshes}')
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

            texture_rewrites = 0
            for source_texture in stream.objects_of_type(nif.NiSourceTexture):
                old_texture_path = canonical(source_texture.filename)
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
                    texture_rewrites += 1

            if texture_rewrites:
                new_mesh_path = private_path(str(relative))
                destination = args.output_data / 'Meshes' / new_mesh_path
                destination.parent.mkdir(parents=True, exist_ok=True)
                stream.save(destination)
                copied_animation_companions += copy_animation_companions(mesh_path, destination)
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
