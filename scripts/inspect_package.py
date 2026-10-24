#!/usr/bin/env python3
"""Read a macOS release bundle and optional ZIP; write an inventory outside it."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--zip', dest='archive', type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    files = []
    for path in sorted(args.bundle.rglob('*')):
        if path.is_file() and not path.is_symlink():
            stat = path.stat()
            files.append({'path': str(path.relative_to(args.bundle)), 'bytes': stat.st_size,
                          'allocated_bytes': stat.st_blocks * 512,
                          'sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
    binary = args.bundle / 'Contents/MacOS/source-editor'
    result = {'platform': platform.platform(), 'files': files,
              'logical_bytes': sum(row['bytes'] for row in files),
              'allocated_file_bytes': sum(row['allocated_bytes'] for row in files),
              'disk_scope': 'regular files only; directory/xattr metadata and APFS shared extents excluded',
              'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest()}
    for name, command in (
        ('architectures', ['xcrun', 'lipo', '-detailed_info', str(binary)]),
        ('dependencies', ['otool', '-L', str(binary)]),
        ('sections', ['xcrun', 'size', '-m', '-arch', 'all', str(binary)]),
    ):
        output = subprocess.check_output(command, text=True)
        (args.output / (name + '.txt')).write_text(output)
    if args.archive:
        with zipfile.ZipFile(args.archive) as archive:
            entries = [{'path': item.filename, 'bytes': item.file_size,
                        'compressed_bytes': item.compress_size} for item in archive.infolist()]
            archived_binary = archive.read(args.bundle.name + '/Contents/MacOS/source-editor')
        result['zip'] = {'bytes': args.archive.stat().st_size, 'entries': entries,
                         'binary_matches': hashlib.sha256(archived_binary).hexdigest() == result['binary_sha256']}
    (args.output / 'inventory.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({key: value for key, value in result.items() if key not in ('files', 'zip')}))
    if args.archive:
        print(json.dumps({'zip_bytes': result['zip']['bytes'], 'binary_matches': result['zip']['binary_matches']}))


if __name__ == '__main__':
    main()
