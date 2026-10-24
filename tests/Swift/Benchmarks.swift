import Foundation
import Darwin

enum BenchmarkRunner {
    private static func usage() -> rusage {
        var value = rusage()
        getrusage(RUSAGE_SELF, &value)
        return value
    }

    private static func milliseconds(_ value: timeval) -> Double {
        Double(value.tv_sec) * 1000 + Double(value.tv_usec) / 1000
    }

    static func run() -> Int32 {
        let targetUnits = 200_000
        var workload = ""
        for index in 0..<7000 {
            workload += String(format: "row%05d 😀 Straße alpha beta\n", 10_000 - index)
        }
        let text = (workload as NSString).substring(to: targetUnits)
        let initialEmojiCount = text.components(separatedBy: "😀").count - 1
        var samples: [[String: Any]] = []
        var allPassed = true

        func measured(_ name: String, _ phase: String, operation: () throws -> [String: Any]) {
            let before = usage()
            let started = DispatchTime.now().uptimeNanoseconds
            var result: [String: Any]
            do { result = try operation() }
            catch { result = ["ok": false, "error": String(describing: error)] }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            let after = usage()
            let cpu = milliseconds(after.ru_utime) + milliseconds(after.ru_stime)
                - milliseconds(before.ru_utime) - milliseconds(before.ru_stime)
            if result["ok"] as? Bool != true { allPassed = false }
            samples.append(["task": name, "phase": phase, "elapsed_ms": elapsed, "cpu_ms": cpu,
                "process_high_water_bytes": after.ru_maxrss, "result": result])
        }

        for phase in ["first_call_in_this_process", "repeat_same_input_in_this_process"] {
            measured("unicode_multiselection_edit", phase) {
                let matches = try SearchEngine.find(in: text, query: "😀", caseSensitive: true)
                let selected = Array(matches.enumerated().filter { $0.offset % 40 == 0 }.prefix(128).map(\.element))
                let result = TextOperations.apply(in: text, edits: selected.map { TextReplacement(range: $0, text: "🙂!") })
                let replacementCount = result.text.components(separatedBy: "🙂!").count - 1
                let remaining = result.text.components(separatedBy: "😀").count - 1
                return ["ok": result.error == nil && replacementCount == selected.count
                    && remaining == initialEmojiCount - selected.count
                    && (result.text as NSString).length == targetUnits + selected.count,
                    "edits": selected.count, "output_utf16_units": (result.text as NSString).length]
            }
            measured("sort_lines", phase) {
                let result = TextOperations.sortLines(in: text, selections: [NSRange(location: 0, length: targetUnits)])
                let lines = result.text.components(separatedBy: "\n")
                let sorted = zip(lines, lines.dropFirst()).allSatisfy { left, right in
                    !Array(right.lowercased().unicodeScalars.map(\.value)).lexicographicallyPrecedes(
                        Array(left.lowercased().unicodeScalars.map(\.value)))
                }
                return ["ok": result.error == nil && sorted && (result.text as NSString).length == targetUnits,
                    "lines": lines.count, "output_utf16_units": (result.text as NSString).length]
            }
            measured("literal_search", phase) {
                let result = try SearchEngine.find(in: text, query: "Straße", regex: false, caseSensitive: true)
                let valid = result.allSatisfy { (text as NSString).substring(with: $0) == "Straße" }
                return ["ok": valid && result.count == initialEmojiCount, "matches": result.count]
            }
        }
        let report: [String: Any] = ["ok": allPassed, "workload_utf16_units": targetUnits, "samples": samples,
            "implementation": "owned Swift TextOperations/SearchEngine", "sublime_comparison": false,
            "measurement_scope": "operation plus result verification; workload construction and process startup excluded",
            "memory_scope": "rusage process high-water RSS in Darwin bytes, cumulative across samples; not per-task peak",
            "phase_scope": "first/repeat calls in one process; no isolated fresh-process cold-start claim",
            "process_family_memory": "not separately measured; benchmark launches no child processes",
            "agent_tokens": "unmeasured", "target_runtime_executed": false]
        do {
            print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
        } catch { fputs("benchmark JSON encoding failed\n", stderr); return 1 }
        return allPassed ? 0 : 1
    }
}
