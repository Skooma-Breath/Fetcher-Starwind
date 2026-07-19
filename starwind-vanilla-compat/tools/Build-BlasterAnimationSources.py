"""Mask Starwind's global Bow/Crossbow overrides and expose a private group.

The output files deliberately retain the source filenames so that, when this
compatibility data folder has higher VFS priority, OpenMW cannot load the
original global Bow/Crossbow replacements.  The Bow sequences become the
private ``swblaster`` handgun groups. Crossbow follow-only files become the
private ``swrifle`` follow group, which the engine uses after a Starwind rifle
shot to avoid the native crossbow bolt-reload tail while retaining its stance.
The private group also names private Starwind sound records so restoring the
shared vanilla bow files does not change blaster audio.
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
    ('xbase_anim/Crossbow; Follow.kf', 'Crossbow', 'swrifle'),
    ('xbase_anim.1st/Crossbow; Follow.kf', 'Crossbow', 'swrifle'),
)

BLASTER_SOUND_IDS = {
    'bowpull': 'SW_Compat_BlasterPull',
    'bowshoot': 'SW_Compat_BlasterShoot',
}


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
        sound_replacements = 0
        for text_data in stream.objects_of_type(nif.NiTextKeyExtraData):
            for index, (time, value) in enumerate(text_data.keys.tolist()):
                parts = []
                count = 0
                entry_sound_replacements = 0
                for line in value.splitlines(keepends=True):
                    if line.lstrip().lower().startswith('sound:'):
                        updated_line = line
                        if new_group == 'swblaster':
                            match = re.match(r'(\s*sound\s*:\s*)(\S+)(.*)', line, flags=re.IGNORECASE)
                            if match:
                                private_sound = BLASTER_SOUND_IDS.get(match.group(2).lower())
                                if private_sound:
                                    updated_line = f'{match.group(1)}{private_sound}{match.group(3)}'
                                    entry_sound_replacements += 1
                        parts.append(updated_line)
                    else:
                        updated_line, line_count = re.subn(re.escape(old_group), new_group, line, flags=re.IGNORECASE)
                        parts.append(updated_line)
                        count += line_count
                updated = ''.join(parts)
                if count or entry_sound_replacements:
                    text_data.keys[index] = (time, updated)
                    replacements += count
                    sound_replacements += entry_sound_replacements
        if replacements == 0:
            raise RuntimeError(f'No {old_group} text keys found in {source}')
        if new_group == 'swblaster' and sound_replacements != len(BLASTER_SOUND_IDS):
            raise RuntimeError(
                f'Expected {len(BLASTER_SOUND_IDS)} private sound-key replacements in {source}, '
                f'found {sound_replacements}'
            )
        destination.parent.mkdir(parents=True, exist_ok=True)
        stream.save(destination)
        verification_stream = nif.NiStream()
        verification_stream.load(destination)
        text_lines = [
            line
            for text_data in verification_stream.objects_of_type(nif.NiTextKeyExtraData)
            for _, value in text_data.keys.tolist()
            for line in value.splitlines()
        ]
        group_lines = [line for line in text_lines if not line.lstrip().lower().startswith('sound:')]
        if not any(line.lower().startswith(f'{new_group.lower()}:') for line in group_lines):
            raise RuntimeError(f'Private group {new_group} was not saved in {destination}')
        if any(line.lower().startswith(f'{old_group.lower()}:') for line in group_lines):
            raise RuntimeError(f'Shared group {old_group} remains in {destination}')

        if new_group == 'swblaster':
            sound_keys = [
                line.split(':', 1)[1].strip()
                for line in text_lines
                if line.lstrip().lower().startswith('sound:')
            ]
            expected_sound_keys = list(BLASTER_SOUND_IDS.values())
            if sorted(sound_keys) != sorted(expected_sound_keys):
                raise RuntimeError(
                    f'Private sound-key verification failed for {destination}: '
                    f'expected {expected_sound_keys}, found {sound_keys}'
                )
        written.append(
            f'{relative}: {replacements} group-key replacements, '
            f'{sound_replacements} private sound-key replacements'
        )

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
