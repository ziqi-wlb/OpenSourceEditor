#!/usr/bin/env python3
"""Standalone acceptance with generated output confined to .build."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('name', nargs='?', default=datetime.datetime.now(datetime.timezone.utc).strftime('local-%Y%m%d-%H%M%S'))
    parser.add_argument('--ui', action='store_true', help='Run desktop checks in a logged-in macOS GUI session')
    parser.add_argument('--arch', choices=['arm64', 'x86_64', 'universal'], default=os.uname().machine)
    args = parser.parse_args()
    if not re.fullmatch(r'[a-zA-Z0-9_-]+', args.name): parser.error('invalid run name')
    app = Path(__file__).resolve().parents[1]
    output = app / '.build/test-results' / args.name
    output.mkdir(parents=True, exist_ok=False)
    rows = {}
    def run(kind, command, timeout=120, style=None):
        folder = output / kind
        folder.mkdir()
        started = time.monotonic()
        with (folder/'stdout.txt').open('w') as out, (folder/'stderr.txt').open('w') as err:
            process = subprocess.Popen(command, cwd=app, stdout=out, stderr=err, start_new_session=True)
            try: code = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGTERM)
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL); process.wait()
                code = -1
        text = (folder/'stdout.txt').read_text()
        row = {'exit_code': code, 'elapsed_seconds': round(time.monotonic()-started, 3),
               'stdout_sha256': digest(folder/'stdout.txt'), 'stderr_sha256': digest(folder/'stderr.txt')}
        if code == 0 and style == 'json':
            result = json.loads(text)
            assert result.get('failed', 0) == 0 and result.get('ok', True), kind
            row.update({key: result[key] for key in ('passed', 'skipped') if key in result})
        elif code == 0 and style == 'ui':
            match = re.search(r'^UI tests: (\d+) passed, 0 failed$', text, re.M)
            assert match, 'Missing successful UI summary'
            row['passed'] = int(match[1])
        elif code == 0 and style == 'sdk':
            text = (folder/'stderr.txt').read_text()
            assert re.search(r'^OK$', text, re.M), kind
            row['passed'] = int(re.search(r'Ran (\d+) tests?', text)[1])
        rows[kind] = row
        (output/'results.json').write_text(json.dumps({'status': 'running' if code == 0 else 'failed', 'checks': rows}, indent=2)+'\n')
        print(kind+': '+str(row), flush=True)
        if code != 0: raise SystemExit(code if code > 0 else 1)
    run('release-build', ['bash','build.sh','--arch',args.arch],timeout=300)
    release = app/'.build/Source Editor.app/Contents/MacOS/source-editor'
    run('release-version', [str(release),'--version'])
    run('release-help', [str(release),'--help'])
    run('portability', [sys.executable,'tests/check_portability.py'])
    run('documentation', [sys.executable,'tests/check_documentation.py'],style='json')
    run('test-build', ['bash','build.sh','--tests'],timeout=180)
    binary = app/'.build/Source Editor Tests.app/Contents/MacOS/source-editor'
    for kind, flag in [('core','--self-test'),('preferences','--preferences-test'),('document-settings','--document-settings-test'),('product-features','--product-features-test'),('daily-features','--daily-features-test'),('services','--service-test'),('benchmark','--benchmark')]:
        run(kind,[str(binary),flag],style='json')
    run('contracts',[str(binary),'--contract-test','tests/fixtures/contracts.json'],style='json')
    run('sdk',[sys.executable,'tests/plugin_host_test.py'],style='sdk')
    run('recovery-crash',[sys.executable,'tests/recovery_crash_test.py',str(binary)],style='json')
    if args.ui:
        run('draft-ui', [str(binary),'--draft-ui-test='+str(output/'draft-ui-artifacts')],timeout=60,style='json')
        run('recovery-restart',[sys.executable,'tests/recovery_restart_test.py',str(binary)],timeout=60,style='json')
        run('daily-ui',[str(binary),'--daily-ui-test','--daily-directory='+str(output/'daily-ui-artifacts')],timeout=45,style='json')
        run('product-ui',[str(binary),'--product-ui-test','--product-directory='+str(output/'product-ui-artifacts')],timeout=60,style='json')
        run('ui',[str(binary),'--ui-self-test',str(output/'ui-artifacts')],timeout=90,style='ui')
        run('multi-window-quit',[str(binary),'--multi-window-quit-test'],timeout=15,style='json')
    inputs = sorted((app/'Sources').glob('*.swift'))+[app/'build.sh',app/'Info.plist',app/'scripts/generate_icon.swift']
    inputs += sorted(p for p in (app/'Resources').rglob('*') if p.is_file() and p.suffix in ('.py','.json'))
    summary = {'status':'passed','checks':rows,'ui_executed':args.ui,
               'release_binary':{'sha256':digest(release),'bytes':release.stat().st_size},
               'test_binary':{'sha256':digest(binary),'bytes':binary.stat().st_size},
               'scope':'tests compile the same production sources with EDITOR_TESTS; release CLI smoke tested separately',
               'native_file_panel_acceptance_verified':False,
               'sources':[{'path':str(p.relative_to(app)),'sha256':digest(p)} for p in inputs]}
    (output/'results.json').write_text(json.dumps(summary,indent=2)+'\n')
    print('Passed. Results: '+str(output.relative_to(app)))
if __name__ == '__main__': main()
