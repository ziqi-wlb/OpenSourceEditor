#!/usr/bin/env python3
"""Measure an unchanged release executable in a copied bundle with a unique identity.

Requires a logged-in macOS GUI and Xcode Command Line Tools. Never attaches to
existing editor processes. Fixtures, snapshots and copied bundles stay in .build.
"""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import time
import uuid


PROBE = '''import AppKit
let pid = pid_t(CommandLine.arguments[1])!
let app = NSRunningApplication(processIdentifier: pid)
let windows = (CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? [])
    .filter { ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid) && ($0[kCGWindowLayer as String] as? Int) == 0 }
let result: [String: Any] = ["bundle_id": app?.bundleIdentifier ?? "", "windows": windows]
let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
print(String(data: data, encoding: .utf8)!)
'''


def footprint_bytes(text):
    match = re.search(r'^Physical footprint:\s+([\d.]+)([KMGT]?)', text, re.M)
    if not match:
        raise RuntimeError('vmmap did not report a physical footprint; inspect the retained snapshot')
    return round(float(match[1]) * 1024 ** (' KMGT'.index(match[2]) if match[2] else 0))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run', help='new directory name inside .build/diagnostics')
    parser.add_argument('--bundle', type=Path, default=Path('.build/Source Editor.app'))
    parser.add_argument('--cases', nargs='+', choices=['empty', 'file', 'multiple'], default=['empty', 'file', 'multiple'])
    parser.add_argument('--duration', type=int, default=30, choices=range(5, 121), metavar='5..120')
    parser.add_argument('--bytes', type=int, default=1048576, choices=[65536, 262144, 1048576, 4194304])
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    if Path(args.run).name != args.run or args.run in ('.', '..'):
        parser.error('run must be a single directory name')
    directory = root / '.build/diagnostics' / args.run
    directory.mkdir(parents=True, exist_ok=False)
    bundle = args.bundle if args.bundle.is_absolute() else root / args.bundle
    binary = bundle / 'Contents/MacOS/source-editor'
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    version = subprocess.check_output([str(binary), '--version'], text=True).strip()
    probe_source = directory / 'probe.swift'
    probe_source.write_text(PROBE)
    probe = directory / 'probe'
    subprocess.run(['xcrun', 'swiftc', '-O', str(probe_source), '-o', str(probe), '-framework', 'AppKit'], check=True)
    manifest = {'version': version, 'binary_sha256': digest, 'platform': platform.platform(),
                'scope': 'unchanged release Mach-O; copied bundle ID; own process only; no editing or scrolling; vmmap values rounded',
                'cases': []}
    for case in args.cases:
        case_dir = directory / case
        case_dir.mkdir()
        copied = case_dir / 'Source Editor Memory Probe.app'
        shutil.copytree(bundle, copied)
        info = copied / 'Contents/Info.plist'
        settings = plistlib.loads(info.read_bytes())
        identity = 'org.sourceeditor.memoryprobe.' + uuid.uuid4().hex
        settings['CFBundleIdentifier'] = identity
        info.write_bytes(plistlib.dumps(settings))
        paths = []
        for index in range(8 if case == 'multiple' else 1 if case == 'file' else 0):
            size = 262144 if case == 'multiple' else args.bytes
            line = '// memory fixture 中文 😀\nlet item = "example"\n'.encode()
            path = case_dir / ('document-' + str(index) + '.swift')
            path.write_bytes(line * (size // len(line)))
            paths.append(path)
        executable = copied / 'Contents/MacOS/source-editor'
        assert hashlib.sha256(executable.read_bytes()).hexdigest() == digest
        row = {'case': case, 'bundle_id': identity, 'fixtures': [
            {'bytes': path.stat().st_size, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()} for path in paths], 'snapshots': []}
        with (case_dir / 'process.log').open('w') as log:
            process = subprocess.Popen([str(executable), *map(str, paths)], cwd=case_dir, stdout=log, stderr=log)
            started = time.monotonic()
            try:
                for deadline in sorted({5, min(15, args.duration), args.duration}):
                    time.sleep(max(0, deadline - (time.monotonic() - started)))
                    if process.poll() is not None:
                        raise RuntimeError('Owned release process exited before its snapshot')
                    native = json.loads(subprocess.check_output([str(probe), str(process.pid)], text=True))
                    visible = [window for window in native['windows'] if window.get('kCGWindowIsOnscreen')]
                    if native['bundle_id'] != identity or len(visible) != 1 or visible[0]['kCGWindowBounds']['Width'] != 1220:
                        raise RuntimeError('Expected owned GUI window was not found')
                    expected = 'Untitled' if case == 'empty' else paths[-1].name
                    title = visible[0].get('kCGWindowName')
                    if title and not title.startswith(expected):
                        raise RuntimeError('Owned window does not show the expected file')
                    vm = subprocess.run(['vmmap', '-summary', str(process.pid)], text=True, capture_output=True)
                    (case_dir / f'vmmap-{deadline}.txt').write_text(vm.stdout + vm.stderr)
                    vm.check_returncode()
                    usage = subprocess.check_output(['ps', '-p', str(process.pid), '-o', 'rss=', '-o', 'time='], text=True).strip().split()
                    snapshot = {'seconds_since_launch': round(time.monotonic() - started, 3),
                                'rss_bytes': int(usage[0]) * 1024, 'cpu_time': usage[1],
                                'physical_footprint_bytes': footprint_bytes(vm.stdout), 'native_window_info': native}
                    row['snapshots'].append(snapshot)
                    print(json.dumps({'case': case, **{k: v for k, v in snapshot.items() if k != 'native_window_info'}}), flush=True)
            finally:
                # All documents belong to the generated read-only workload; the Popen
                # handle identifies the only process this runner is allowed to stop.
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
                # Normal release UI writes preferences to its unique bundle domain.
                # Remove only this generated domain, retaining any failure evidence.
                cleanup = subprocess.run(['defaults', 'delete', identity], text=True, capture_output=True)
                row['preference_cleanup'] = {'return_code': cleanup.returncode, 'stderr': cleanup.stderr.strip()}
                saved_state = Path.home() / 'Library/Saved Application State' / (identity + '.savedState')
                try:
                    if saved_state.exists():
                        shutil.rmtree(saved_state)
                except OSError as error:
                    row['saved_state_cleanup_error'] = str(error)
                manifest['cases'].append(row)
                (directory / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')


if __name__ == '__main__':
    main()
