#!/usr/bin/env python3
"""Real AppKit normal quit/restart, using only temporary documents and support."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

binary = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="source-editor-normal-restart-") as directory:
    root = Path(directory)
    result = subprocess.run([str(binary), "--draft-restart-write=" + directory], capture_output=True, text=True, timeout=20)
    assert result.returncode == 0 and json.loads(result.stdout)["ok"], result.stdout + result.stderr
    snapshots = list((root / "support/Recovery").glob("*.json"))
    assert len(snapshots) == 2 and all(json.loads(path.read_text())["closedNormally"] for path in snapshots)
    assert (root / "original.md").read_text() == "# Disk original"
    result = subprocess.run([str(binary), "--draft-restart-read=" + directory], capture_output=True, text=True, timeout=20)
    read = json.loads(result.stdout)
    assert result.returncode == 0 and read["failed"] == 0, result.stdout + result.stderr
    assert (root / "original.md").read_text() == "# Disk original"
print(json.dumps({"passed": 5 + read["passed"], "failed": 0, "scope": "real normal application termination, two windows, final edits, clean tabs, untitled note, restart and source-byte preservation"}))
