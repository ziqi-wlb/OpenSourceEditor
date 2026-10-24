#!/usr/bin/env python3
"""Validate bilingual guides, local navigation and the app-owned release metadata."""
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys

def main():
    app = Path(__file__).resolve().parents[1]
    files = list(app.glob('*.md')) + list((app/'docs').glob('*.md')) + list((app/'windows').glob('*.md'))
    repo = app.parent
    if (repo/'editor').resolve() == app:
        files += [repo/'README.md', repo/'README.zh-CN.md', repo/'CONTRIBUTING.md', repo/'CONTRIBUTING.zh-CN.md',
                  repo/'docs/VALIDATION.md', repo/'docs/VALIDATION.zh-CN.md']
    pairs = 0
    for path in files:
        if '.zh-CN' not in path.stem:
            counterpart = path.with_name(path.stem+'.zh-CN.md')
            assert counterpart.is_file(), 'Missing Chinese guide: '+str(path)
            assert f']({counterpart.name})' in path.read_text(), 'Missing language switch: '+str(path)
            pairs += 1
        else:
            counterpart = path.with_name(path.name.replace('.zh-CN.md', '.md'))
            assert counterpart.is_file(), 'Missing English guide: '+str(path)
            assert f']({counterpart.name})' in path.read_text(), 'Missing language switch: '+str(path)
        text = re.sub(r'```[\s\S]*?```', '', path.read_text())
        for target in re.findall(r'\]\(([^)]+)\)', text):
            target = target.split('#', 1)[0]
            if target and not re.match(r'[a-zA-Z][a-zA-Z0-9+.-]*:', target):
                assert (path.parent/target).exists(), 'Broken local link: '+str(path)+' -> '+target
    metadata = json.loads((app/'Resources/project-information.json').read_text())
    version = plistlib.loads((app/'Info.plist').read_bytes())['CFBundleShortVersionString']
    versions = [release['version'] for release in metadata['releases']]
    assert versions[0] == version and len(versions) == len(set(versions)), 'Release metadata/version mismatch'
    assert metadata['author'] and '@' in metadata['email'], 'Missing author contact'
    for release in metadata['releases']:
        assert release['changes'] and all(change['english'].strip() and change['chinese'].strip() for change in release['changes'])
    subprocess.run([sys.executable, str(app/'scripts/generate_release_notes.py'), '--check'], check=True, stdout=subprocess.DEVNULL)
    print(json.dumps({'ok': True, 'paired_guides': pairs, 'documents': len(files), 'release_version': version}))

if __name__ == '__main__': main()
