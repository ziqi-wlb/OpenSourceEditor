#!/usr/bin/env python3
"""Opt-in native performance workloads in isolated, supervised processes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]

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
                "scope": "serial fresh GUI process per case; filesystem caches not flushed; polling RSS is approximate",
                "cycles": args.cycles,
                "cases": []}
    failures = 0
    for case in args.cases:
        scenario, size = case.split(":")
        if scenario not in ("file", "comment", "multiple", "undo") or int(size) <= 0:
            parser.error("cases must be file|comment|multiple|undo:positive_bytes")
        directory = output / (scenario + "-" + size)
        directory.mkdir()
        started = time.monotonic()
        peak_rss = 0
        reason = None
        print("RUN", case, flush=True)
        with (directory / "stdout.txt").open("w") as stdout, (directory / "stderr.txt").open("w") as stderr:
            process = subprocess.Popen([str(binary), "--performance-test", "--performance-directory=" + str(directory),
                                        "--performance-scenario=" + scenario, "--performance-bytes=" + size],
                                       cwd=ROOT, stdout=stdout, stderr=stderr, start_new_session=True,
                                       env={**os.environ, "SOURCE_EDITOR_PERF_CYCLES": str(args.cycles)})
            while process.poll() is None:
                rss_text = subprocess.run(["ps", "-o", "rss=", "-p", str(process.pid)], capture_output=True, text=True).stdout.strip()
                rss = int(rss_text or 0) * 1024
                peak_rss = max(peak_rss, rss)
                if rss > args.max_rss_mib * 1024 * 1024 or time.monotonic() - started > args.timeout:
                    reason = "RSS limit" if rss > args.max_rss_mib * 1024 * 1024 else "timeout"
                    # Only sample/stop this owned process group, never a user's window.
                    subprocess.run(["sample", str(process.pid), "2", "1", "-file", str(directory / "sample.txt")],
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
                  "exit_code": process.returncode, "sampled_peak_rss_bytes": peak_rss, "stop_reason": reason}
        fixture = directory / "fixture.swift"
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
        print(json.dumps(result), flush=True)
    return int(bool(failures))

if __name__ == "__main__":
    raise SystemExit(main())
