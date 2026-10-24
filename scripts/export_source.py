#!/usr/bin/env python3
"""Export this editor alone, without local artifacts or investigation files."""
import argparse
from pathlib import Path
import tarfile

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('output',type=Path)
    parser.add_argument('--with-tests',action='store_true')
    args=parser.parse_args()
    app=Path(__file__).resolve().parents[1]
    files=[app/p for p in ('README.md','PERFORMANCE.md','plugins.md','Info.plist','build.sh','package.sh','windows/.clang-format')]
    folders=['Sources','Resources','scripts','windows']+(['tests'] if args.with_tests else [])
    extensions={'.swift','.py','.json','.sh','.cpp','.ps1','.md'}
    for folder in folders:
        files.extend(p for p in (app/folder).rglob('*') if p.is_file() and p.suffix in extensions
                     and (args.with_tests or p.name != 'tests.cpp')
                     and not any(part in ('.build','__pycache__') for part in p.relative_to(app).parts))
    license_file=app.parent/'LICENSE'
    if license_file.is_file():files.append(license_file)
    args.output.parent.mkdir(parents=True,exist_ok=True)
    if args.output.exists():raise SystemExit('Use a new output filename; existing archives are preserved')
    def portable_metadata(info):
        info.uid=info.gid=0;info.uname=info.gname='';info.mtime=0
        return info
    with tarfile.open(args.output,'w:gz') as archive:
        for path in sorted(set(files)):
            relative=path.relative_to(app) if app in path.parents else Path('LICENSE')
            archive.add(path,arcname=str(Path('SourceEditor')/relative),recursive=False,filter=portable_metadata)
    print(str(args.output))
if __name__=='__main__':main()
