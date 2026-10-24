#!/usr/bin/env python3
"""Generate bilingual release documents from the metadata shipped in the app."""
import argparse
import json
from pathlib import Path

def documents(app):
    metadata = json.loads((app/'Resources/project-information.json').read_text())
    for language, suffix, title, contact in [('english', '', 'Release notes', 'Author'),
                                             ('chinese', '.zh-CN', '版本说明', '作者')]:
        counterpart = 'RELEASE_NOTES.zh-CN.md' if language == 'english' else 'RELEASE_NOTES.md'
        label = '中文' if language == 'english' else 'English'
        text = f'# Source Editor {title}\n\n[{label}]({counterpart})\n\n'
        text += f'{contact}: {metadata["author"]} · [{metadata["email"]}](mailto:{metadata["email"]})\n\n'
        for release in metadata['releases']:
            text += f'## {release["version"]}\n\n'
            text += '\n'.join('- '+change[language] for change in release['changes'])+'\n\n'
        yield app/f'RELEASE_NOTES{suffix}.md', text.rstrip()+'\n'

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    app = Path(__file__).resolve().parents[1]
    for path, text in documents(app):
        if args.check:
            if not path.is_file() or path.read_text() != text: raise SystemExit('Outdated release document: '+path.name)
        else: path.write_text(text)
    print('Bilingual release notes '+('verified' if args.check else 'generated'))

if __name__ == '__main__': main()
