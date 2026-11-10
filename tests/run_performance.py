#!/usr/bin/env python3
"""Opt-in native performance workloads in isolated, supervised processes."""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import signal
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]

LAUNCHER = r'''import AppKit
import Darwin
var stopping = false
signal(SIGTERM) { _ in stopping = true }
let bundle = URL(fileURLWithPath: CommandLine.arguments[1])
let configuration = NSWorkspace.OpenConfiguration()
configuration.createsNewApplicationInstance = true
configuration.arguments = Array(CommandLine.arguments.dropFirst(3))
configuration.environment = ["SOURCE_EDITOR_PERF_CYCLES": CommandLine.arguments[2]]
var launched: NSRunningApplication?
var launchError: Error?
var completed = false
NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { app, error in
    launched = app; launchError = error; completed = true
}
let launchDeadline = Date().addingTimeInterval(15)
while !completed && Date() < launchDeadline {
    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
}
guard let app = launched, app.bundleURL?.standardizedFileURL == bundle.standardizedFileURL else {
    fputs("Owned application launch failed: \(String(describing: launchError))\n", stderr)
    exit(1)
}
print(app.processIdentifier); fflush(stdout)
let deadline = Date().addingTimeInterval(180)
while !app.isTerminated && !stopping && Date() < deadline {
    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
}
if !app.isTerminated {
    // This is the NSRunningApplication token returned for the generated probe.
    // It contains only owned workload files, never a user's editor window.
    app.forceTerminate()
    exit(2)
}
'''

def process_family(pid):
    """WebKit XPC helpers have launchd parents. Use OS responsibility attribution.

    This optional diagnostic symbol is never linked into the editor. If it is
    unavailable, record incomplete scope instead of counting other apps' helpers.
    """
    try:
        responsible = ctypes.CDLL('/usr/lib/libSystem.B.dylib').responsibility_get_pid_responsible_for_pid
        responsible.argtypes, responsible.restype = [ctypes.c_int], ctypes.c_int
    except (OSError, AttributeError):
        responsible = None
    output = subprocess.run(['ps', '-axo', 'pid=,rss=,comm='], text=True, capture_output=True, check=True).stdout
    members = []
    root_responsibility = responsible(pid) if responsible else None
    for line in output.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) != 3:
            continue
        candidate, rss, executable = int(fields[0]), int(fields[1]), fields[2]
        if candidate == pid or (responsible and '/System/Library/Frameworks/WebKit.framework/' in executable and responsible(candidate) == pid):
            members.append({'pid': candidate, 'rss_bytes': rss * 1024, 'executable': executable,
                            'responsibility_pid': responsible(candidate) if responsible else None})
    return {'members': members, 'rss_bytes': sum(row['rss_bytes'] for row in members),
            'webkit_attribution_available': responsible is not None and root_responsibility == pid}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("name", help="new output directory name under .build/performance")
    parser.add_argument("--no-build", action="store_true")
    parser.add_argument("--binary", type=Path)
    parser.add_argument("--source-root", type=Path, default=ROOT, help="source tree corresponding to a pinned binary")
    parser.add_argument("--cases", nargs="+", default=["file:65536", "file:1048576", "file:4194304", "multiple:262144", "undo:262144"])
    parser.add_argument("--timeout", type=float, default=90)
    parser.add_argument("--cycles", type=int, default=4, help="eight files per multiple/undo cycle")
    parser.add_argument("--max-rss-mib", type=int, default=1536)
    args = parser.parse_args()
    if args.cycles < 1:
        parser.error("--cycles must be positive")
    if Path(args.name).name != args.name:
        parser.error("name must be a directory name")
    output = ROOT / ".build" / "performance" / args.name
    output.mkdir(parents=True, exist_ok=False)
    if not args.binary and not args.no_build:
        subprocess.run(["bash", "build.sh", "--tests"], cwd=ROOT, check=True)
    original = args.binary or ROOT / ".build" / "Source Editor Tests.app" / "Contents" / "MacOS" / "source-editor"
    original = original.resolve()
    # Pin the entire bundle: later builds cannot replace this measured artifact.
    bundle = next((p for p in original.parents if p.suffix == ".app"), None)
    if bundle:
        shutil.copytree(bundle, output / bundle.name)
        binary = output / bundle.name / original.relative_to(bundle)
        copied_info = output / bundle.name / 'Contents/Info.plist'
        info = plistlib.loads(copied_info.read_bytes())
        identity = 'org.sourceeditor.performance.' + uuid.uuid4().hex
        info['CFBundleIdentifier'] = identity
        info.pop('CFBundleDocumentTypes', None)
        info.pop('UTImportedTypeDeclarations', None)
        copied_info.write_bytes(plistlib.dumps(info))
        launcher_source = output / 'launch.swift'
        launcher_source.write_text(LAUNCHER)
        launcher = output / 'launch'
        subprocess.run(['xcrun', 'swiftc', str(launcher_source), '-o', str(launcher), '-framework', 'AppKit'], check=True)
    else:
        binary = output / "performance-test"
        shutil.copy2(original, binary)
    source_hash = hashlib.sha256()
    for path in sorted((args.source_root / "Sources").glob("*.swift")):
        source_hash.update(path.name.encode()); source_hash.update(path.read_bytes())
    manifest = {"platform": platform.platform(), "machine": platform.machine(),
                "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                "source_sha256": source_hash.hexdigest(),
                "workload_sha256": hashlib.sha256((args.source_root / "tests/Swift/PerformanceTests.swift").read_bytes()).hexdigest(),
                "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
                "compiler": subprocess.check_output(["swiftc", "--version"], text=True).strip(),
                "scope": "serial fresh GUI process per case; copied bundle has unique diagnostic identity; LaunchServices establishes app responsibility; filesystem caches not flushed; polling RSS is approximate",
                "cycles": args.cycles,
                "cases": []}
    failures = 0
    for case in args.cases:
        scenario, size = case.split(":")
        if scenario not in ("file", "comment", "multiple", "undo", "markdown", "sidebar") or int(size) <= 0:
            parser.error("cases must be file|comment|multiple|undo|markdown|sidebar:positive_bytes")
        directory = output / (scenario + "-" + size)
        directory.mkdir()
        started = time.monotonic()
        peak_rss = 0
        peak_family_rss = 0
        family_snapshots = []
        last_family_phase = None
        reason = None
        print("RUN", case, flush=True)
        with (directory / "stdout.txt").open("w") as stdout, (directory / "stderr.txt").open("w") as stderr:
            native_arguments = ["--performance-test", "--performance-directory=" + str(directory),
                                "--performance-scenario=" + scenario, "--performance-bytes=" + size]
            command = [str(launcher), str(output / bundle.name), str(args.cycles), *native_arguments] if bundle else [str(binary), *native_arguments]
            process = subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE if bundle else stdout, stderr=stderr,
                                       text=True, start_new_session=True, env={**os.environ, "SOURCE_EDITOR_PERF_CYCLES": str(args.cycles)})
            if bundle:
                # The launcher only emits the PID of its verified application token.
                native_pid = int(process.stdout.readline().strip())
                stdout.write('Owned native PID: ' + str(native_pid) + '\n'); stdout.flush()
            else:
                native_pid = process.pid
            next_family_snapshot = 0
            while process.poll() is None:
                rss_text = subprocess.run(["ps", "-o", "rss=", "-p", str(native_pid)], capture_output=True, text=True).stdout.strip()
                rss = int(rss_text or 0) * 1024
                peak_rss = max(peak_rss, rss)
                family = process_family(native_pid)
                peak_family_rss = max(peak_family_rss, family['rss_bytes'])
                phases = (directory / 'stdout.txt').read_text().splitlines()
                phase = next((line[5:] for line in reversed(phases) if line.startswith('PERF ')), 'launch')
                if phase != last_family_phase or time.monotonic() >= next_family_snapshot:
                    family_snapshots.append({'phase': phase, 'elapsed_seconds': time.monotonic() - started, **family})
                    last_family_phase = phase
                    next_family_snapshot = time.monotonic() + 1
                if family['rss_bytes'] > args.max_rss_mib * 1024 * 1024 or time.monotonic() - started > args.timeout:
                    reason = "Family RSS limit" if family['rss_bytes'] > args.max_rss_mib * 1024 * 1024 else "timeout"
                    # Only sample/stop this owned process group, never a user's window.
                    subprocess.run(["sample", str(native_pid), "2", "1", "-file", str(directory / "sample.txt")],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                    break
                time.sleep(0.1)
            process.wait()
        result = {"case": case, "elapsed_ms": (time.monotonic() - started) * 1000,
                  "exit_code": process.returncode, "sampled_peak_rss_bytes": peak_rss,
                  "sampled_peak_family_rss_bytes": peak_family_rss, "family_snapshots": family_snapshots, "stop_reason": reason}
        fixture = directory / ("fixture.md" if scenario == 'markdown' else "fixture.swift")
        if fixture.exists():
            result["fixture_sha256"] = hashlib.sha256(fixture.read_bytes()).hexdigest()
            result["fixture_bytes"] = fixture.stat().st_size
        metrics_path = directory / "metrics.json"
        if metrics_path.exists():
            metrics = json.loads(metrics_path.read_text())
            result["failed"] = metrics["failed"]
            result["max_heartbeat_delay_ms"] = metrics["max_heartbeat_delay_ms"]
        else:
            result["failed"] = ["no completed metrics"]
        failures += bool(reason or process.returncode or result["failed"])
        manifest["cases"].append(result)
        (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        print(json.dumps({k: v for k, v in result.items() if k != 'family_snapshots'}), flush=True)
    return int(bool(failures))

if __name__ == "__main__":
    raise SystemExit(main())
