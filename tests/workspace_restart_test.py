#!/usr/bin/env python3
"""Separate AppKit processes with isolated projects, preferences and recovery."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

binary = Path(sys.argv[1]).resolve()
passed = 0
for mode in ("closed", "quit", "off"):
    with tempfile.TemporaryDirectory(prefix="source-editor-workspace-") as directory:
        root = Path(directory)
        for step in ("write", "read"):
            result = subprocess.run([str(binary), f"--workspace-restart-{step}={directory}", f"--workspace-mode={mode}"], capture_output=True, text=True, timeout=20)
            assert result.returncode == 0, result.stdout + result.stderr
            data = json.loads(result.stdout)
            assert data.get("failed", 0) == 0 and data.get("ok", True), data
            passed += data["passed"]
            assert (root / "project/original.md").read_text() == "# Disk original"
            passed += 1
print(json.dumps({"passed": passed, "failed": 0, "scope": "separate processes: folder-only final close, normal Keep Drafts quit, disabled restoration, sidebar/layout and original bytes"}))
