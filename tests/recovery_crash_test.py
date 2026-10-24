#!/usr/bin/env python3
"""Exercise a real background snapshot across abrupt process exit and restart."""
import json
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

binary = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="source-editor-recovery-") as directory:
    root = Path(directory)
    written = subprocess.run([str(binary), "--recovery-abrupt-write=" + directory], capture_output=True, text=True, timeout=15)
    assert written.returncode == 86, written.stderr
    snapshot = Path(written.stdout.strip())
    assert snapshot.parent.resolve() == root.resolve() and snapshot.suffix == '.json'
    assert stat.S_IMODE(snapshot.stat().st_mode) == 0o600
    assert json.loads(snapshot.read_text())["documents"][0]["text"] == "unsaved recovery 中文😀"
    (root / "original.txt").write_text("changed after crash")
    read = subprocess.run([str(binary), "--recovery-read=" + str(snapshot)], capture_output=True, text=True, timeout=15)
    assert read.returncode == 0 and json.loads(read.stdout)["ok"], read.stdout + read.stderr
    assert (root / "original.txt").read_text() == "changed after crash"
    snapshot.write_text('{"version":')
    corrupt = subprocess.run([str(binary), "--recovery-read=" + str(snapshot)], capture_output=True, text=True, timeout=15)
    assert corrupt.returncode != 0 and snapshot.exists(), 'Malformed recovery must remain available for inspection'
print(json.dumps({"passed": 6, "failed": 0, "scope": "abrupt exit after write, restart, private file permissions, changed disk protection, corrupt snapshot retained"}))
