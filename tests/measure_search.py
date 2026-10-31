#!/usr/bin/env python3
"""Compare complete replacement against a pinned editor source baseline.

This is a Foundation-only production algorithm benchmark, not GUI latency.
Requires Xcode Command Line Tools. Generated sources/results stay in .build.
"""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import re
import subprocess
import time


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def section(source, start, end):
    first = source.index(start)
    return source[first:source.index(end, first + len(start))]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('name', help='new run directory under .build/diagnostics')
    parser.add_argument('--baseline-ref', default='9c719a9')
    parser.add_argument('--baseline-file', type=Path, help='EditorCore.swift from the baseline, for standalone exports without Git history')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_-]+', args.name):
        parser.error('name must be one directory component')
    root = Path(__file__).resolve().parents[1]
    output = root / '.build/diagnostics' / args.name
    output.mkdir(parents=True, exist_ok=False)
    if args.baseline_file:
        baseline = args.baseline_file.read_text()
    else:
        repo=Path(subprocess.check_output(['git','rev-parse','--show-toplevel'],cwd=root,text=True).strip())
        source_path=(root/'Sources/EditorCore.swift').relative_to(repo).as_posix()
        baseline = subprocess.check_output(['git','show',args.baseline_ref+':'+source_path],cwd=repo,text=True)
    current_core = (root / 'Sources/EditorCore.swift').read_text()
    # Use the exact historical replacement/apply bodies and current boundary
    # contracts. Compilation fails if those contracts no longer agree.
    legacy_apply = section(baseline, '    static func apply(in text: String', '\n    static func ')
    legacy_search = baseline[baseline.index('enum SearchEngine {'):].replace('enum SearchEngine {', 'enum LegacySearch {').replace('TextOperations.apply', 'LegacyOperations.apply')
    boundary = section(current_core, '    static func isBoundary(', '\n    static func ')
    types = section(current_core, 'struct TextReplacement {', 'enum TextOperations {')
    error = section(current_core, 'enum EditorFailure:', 'final class EditorDocument:')
    (output / 'Support.swift').write_text('import Foundation\n' + error + types + 'enum TextOperations {\n' + boundary + '\n}\n')
    (output / 'Legacy.swift').write_text('import Foundation\nenum LegacyOperations {\n' + boundary + legacy_apply + '\n}\n' + legacy_search)
    (output / 'main.swift').write_text('''import Foundation
let mode = CommandLine.arguments[1]
let count = 1000
let text = String(repeating: "needle" + String(repeating: "x", count: 994), count: count)
let expected = text.replacingOccurrences(of: "needle", with: "changed")
let expectedCursors = (0..<count).map { NSRange(location: $0 * 1001 + 7, length: 0) }
var times: [Double] = []
for _ in 0..<3 {
    let began = ProcessInfo.processInfo.systemUptime
    let result = try mode == "legacy" ? LegacySearch.replacing(in: text, query: "needle", replacement: "changed") : SearchEngine.replacing(in: text, query: "needle", replacement: "changed")
    guard result.text == expected, result.selections == expectedCursors else { fatalError("Incorrect output") }
    times.append(ProcessInfo.processInfo.systemUptime - began)
}
let row: [String: Any] = ["mode": mode, "times_seconds": times, "utf16_units": text.utf16.count, "matches": count, "equivalent_output_and_cursors": true]
print(String(data: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), encoding: .utf8)!)
''')
    binary = output / 'search-benchmark'
    subprocess.run(['xcrun', 'swiftc', '-O', str(output/'Support.swift'), str(output/'Legacy.swift'),
                    str(root/'Sources/SearchEngine.swift'), str(output/'main.swift'), '-o', str(binary)], check=True)
    rows = []
    for mode in ('legacy', 'linear'):
        began = time.monotonic()
        result = subprocess.run(['/usr/bin/time', '-l', str(binary), mode], capture_output=True, text=True, timeout=30, check=True)
        (output / (mode + '-stdout.txt')).write_text(result.stdout)
        (output / (mode + '-time.txt')).write_text(result.stderr)
        row = json.loads(result.stdout)
        row['process_elapsed_seconds'] = time.monotonic() - began
        cpu = re.search(r'([\d.]+) user\s+([\d.]+) sys', result.stderr)
        peak = re.search(r'(\d+)\s+maximum resident set size', result.stderr)
        if not cpu or not peak:
            raise RuntimeError('Missing macOS time CPU/memory result')
        row.update(cpu_user_seconds=float(cpu[1]), cpu_system_seconds=float(cpu[2]), peak_process_rss_bytes=int(peak[1]))
        rows.append(row)
    manifest = {'scope': 'Foundation production algorithms, complete equivalent output/cursors; one fresh process per mode, first and two warm calls; no GUI/undo/storage commit; OS caches not flushed; no child processes',
                'platform': platform.platform(), 'baseline_ref': args.baseline_ref if not args.baseline_file else None,
                'baseline_sha256': hashlib.sha256(baseline.encode()).hexdigest(),
                'current_search_sha256': sha(root/'Sources/SearchEngine.swift'),
                'compiler': subprocess.check_output(['swiftc', '--version'], text=True).strip(), 'rows': rows}
    (output/'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
    print(json.dumps(manifest))


if __name__ == '__main__':
    main()
