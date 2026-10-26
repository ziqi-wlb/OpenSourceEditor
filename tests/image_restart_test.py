#!/usr/bin/env python3
"""Check native image/session restoration in separate test processes."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

binary = Path(sys.argv[1]).resolve()
passed = 0
with tempfile.TemporaryDirectory(prefix='source-editor-image-') as temporary:
    for phase in ('write', 'read'):
        result = subprocess.run([str(binary), '--image-restart-'+phase+'='+str(Path(temporary).resolve())],
                                text=True, capture_output=True, timeout=25)
        if result.returncode:
            raise SystemExit(result.stdout + result.stderr)
        row = json.loads(result.stdout)
        assert row['failed'] == 0, row
        passed += row['passed']
print(json.dumps({'passed': passed, 'failed': 0, 'scope': 'separate-process native image and mixed split restoration'}))
