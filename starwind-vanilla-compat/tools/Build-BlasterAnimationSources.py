"""Mask Starwind's global Bow/Crossbow overrides and expose a private group.

The output files deliberately retain the source filenames so that, when this
compatibility data folder has higher VFS priority, OpenMW cannot load the
original global Bow/Crossbow replacements.  The Bow sequences become the
private ``swblaster`` groups; Crossbow follow-only files become unused groups.
"""

from __future__ import annotations

import argparse
import re
import shutil
import sys
from pathlib import Path


ADDON_LIB = Path(r"C:\Users\REPTILE\AppData\Roaming\Blender Foundation\Blender\4.5\scripts\addons\io_scene_mw\lib")


SOURCES = (
    ('xbase_anim/Bow_Anim.kf', 'BowAndArrow', 'swblaster'),
    ('xbase_anim.1st/Bow_Anim_bend_1st.kf', 'BowAndArrow', 'swblaster'),
    ('xbase_anim/Crossbow; Follow.kf', 'Crossbow', 'swblaster_unused'),
    ('xbase_anim.1st/Crossbow; Follow.kf', 'Crossbow', 'swblaster_unused'),
)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--source-data', type=Path, required=True)
    parser.add_argument('--output-data', type=Path, required=True)
    parser.add_argument('--assets', type=Path, required=True)
    args = parser.parse_args()

    if not ADDON_LIB.is_dir():
        raise FileNotFoundError(f'Greatness7 NIF library was not found: {ADDON_LIB}')
    sys.path.insert(0, str(ADDON_LIB))
    from es3 import nif  # pylint: disable=import-outside-toplevel

    written = []
    for relative, old_group, new_group in SOURCES:
        source = args.source_data / 'Animations' / relative
        destination = args.output_data / 'Animations' / relative
        if not source.is_file():
            raise FileNotFoundError(f'Missing Starwind animation source: {source}')
        stream = nif.NiStream()
        stream.load(source)
        replacements = 0
        for text_data in stream.objects_of_type(nif.NiTextKeyExtraData):
            for index, (time, value) in enumerate(text_data.keys.tolist()):
                parts = []
                count = 0
                for line in value.splitlines(keepends=True):
                    if line.lstrip().lower().startswith('sound:'):
                        parts.append(line)
                    else:
                        updated_line, line_count = re.subn(re.escape(old_group), new_group, line, flags=re.IGNORECASE)
                        parts.append(updated_line)
                        count += line_count
                updated = ''.join(parts)
                if count:
                    text_data.keys[index] = (time, updated)
                    replacements += count
        if replacements == 0:
            raise RuntimeError(f'No {old_group} text keys found in {source}')
        destination.parent.mkdir(parents=True, exist_ok=True)
        stream.save(destination)
        written.append(f'{relative}: {replacements} group-key replacements')

    script_source = args.assets / 'scripts' / 'starwind-compat' / 'blaster-animation-controller.lua'
    manifest_source = args.assets / 'StarwindVanillaCompatAnimationExperimental.omwscripts'
    script_destination = args.output_data / 'scripts' / 'starwind-compat' / script_source.name
    manifest_destination = args.output_data / manifest_source.name
    script_destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(script_source, script_destination)
    shutil.copy2(manifest_source, manifest_destination)
    print('\n'.join(written))


if __name__ == '__main__':
    main()
