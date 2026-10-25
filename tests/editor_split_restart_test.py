#!/usr/bin/env python3
"""Restore split desktop/session state in a fresh native test process."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

binary = Path(sys.argv[1]).resolve()
passed = 0
with tempfile.TemporaryDirectory(prefix='source-editor-split-') as temporary:
    directory = Path(temporary).resolve()
    for phase in ('write', 'read'):
        result = subprocess.run([str(binary), '--split-restart-'+phase+'='+str(directory)],
                                text=True, capture_output=True, timeout=25)
        if result.returncode:
            raise SystemExit(result.stdout + result.stderr)
        row = json.loads(result.stdout)
        assert row['failed'] == 0, row
        passed += row['passed']
print(json.dumps({'passed': passed, 'failed': 0, 'scope': 'separate-process native editor split desktop and session restoration'}))
