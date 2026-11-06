#!/usr/bin/env python3
"""Create a verified file index for iOS SMB providers that cannot enumerate folders."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import tempfile

INDEX = 'PC98PLAYER.FILES.json'

def index_game(root):
    if not (root / 'PC98PLAYER.INI').is_file():
        raise ValueError(f'PC98PLAYER.INI is missing: {root}')
    entries = []
    for path in sorted(root.rglob('*')):
        relative = path.relative_to(root)
        if any(part.startswith('.') or part == 'PC98PLAYER.SAV' for part in relative.parts) or path.name == INDEX:
            continue
        if path.is_symlink():
            raise ValueError(f'Symbolic links are not supported: {path}')
        if not path.is_file():
            continue
        digest = hashlib.sha256()
        size = 0
        with path.open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                size += len(chunk)
                digest.update(chunk)
        entries.append({'path': relative.as_posix(), 'size': size, 'sha256': digest.hexdigest()})
    if not entries:
        raise ValueError(f'No game files found: {root}')
    contents = json.dumps({'version': 1, 'files': entries}, ensure_ascii=False, indent=2) + '\n'
    with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', prefix='.' + INDEX, dir=root, delete=False) as stream:
        temporary = Path(stream.name)
        stream.write(contents)
    try:
        os.replace(temporary, root / INDEX)
    finally:
        temporary.unlink(missing_ok=True)
    print(f'{root}: {len(entries)} files')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder', type=Path)
    parser.add_argument('--recursive', action='store_true', help='Index all game folders below the selected library.')
    args = parser.parse_args()
    root = args.folder.resolve(strict=True)
    roots = sorted({p.parent for p in root.rglob('PC98PLAYER.INI')}) if args.recursive else [root]
    if not roots:
        parser.error('No PC98PLAYER.INI files found.')
    for game in roots:
        if not game.is_relative_to(root):
            raise ValueError('Game folder is outside the selected library.')
        index_game(game)

if __name__ == '__main__':
    main()
