#!/usr/bin/env python3
"""Check public source paths and the production bundle's content boundary."""
from pathlib import Path
import re
import subprocess

app=Path(__file__).resolve().parents[1]
repo=app.parent
personal_path=re.compile(r'/(?:Users|home)/[A-Za-z0-9_.-]+')
paths=[]
try:
    paths=[repo/name for name in subprocess.check_output(['git','ls-files'],cwd=repo,text=True).splitlines()]
except subprocess.CalledProcessError:
    paths=[p for p in app.rglob('*') if '.build' not in p.parts and '__pycache__' not in p.parts]
for path in paths:
    if path.is_file() and path.suffix in ('.md','.swift','.py','.json','.sh','.ps1','.cpp','.yml'):
        assert not personal_path.search(path.read_text()), 'Personal directory in '+str(path.relative_to(repo))
release=app/'.build/Source Editor.app/Contents'
assert not list((release/'Resources').rglob('*.pyc'))
assert not list((release/'Resources').rglob('__pycache__'))
assert not list((release/'Resources').rglob('*.swift'))
symbols=subprocess.check_output(['nm',str(release/'MacOS/source-editor')],text=True,stderr=subprocess.DEVNULL)
for name in ('UITestRunner','CoreTestRunner','BenchmarkRunner','ServiceTestRunner',
             'PreferencesTestRunner','DocumentSettingsTestRunner','ContractTestRunner',
             'LifecycleUITests','ContextMenuUITests','MultiWindowUITests','MultiWindowQuitTests','PerformanceTests','ProductFeatureTests','ProductUITests','DailyFeatureTests','DailyUITests','DraftRecoveryUITests','RecoveryPerformanceTests'):
    assert name not in symbols, 'Test code bundled in release'
print('Portable source paths and production-only bundle verified')
