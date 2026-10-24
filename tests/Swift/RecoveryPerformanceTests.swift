import Foundation
import Darwin

/// Isolated process measurement of real recovery capture/encode/write. This
/// excludes GUI layout; native open/edit/scroll workloads remain separate.
enum RecoveryPerformanceTests {
    static func run(units: Int) -> Int32 {
        guard [65536, 1048576, 4194304].contains(units) else { return 2 }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-measure-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = EditorDocument(text: String(repeating: "x", count: units - 4) + "中文😀")
        let owner = EditorRecovery(directory: directory)
        var rows: [[String: Any]] = [], ok = true
        func cpu(_ usage: rusage) -> Double {
            Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000 + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000
        }
        for phase in ["first-write", "repeat-write"] {
            var before = rusage(); getrusage(RUSAGE_SELF, &before)
            let started = DispatchTime.now().uptimeNanoseconds
            let snapshot = EditorSession(selectedIndex: 0, split: false, documents: [.init(document: document, ranges: [.init(location: 0, length: 0)])])
            var finished = false, failure: Error?
            owner.write(snapshot) { error in failure = error; finished = true }
            let deadline = Date().addingTimeInterval(10)
            while !finished && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.001)) }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            var after = rusage(); getrusage(RUSAGE_SELF, &after)
            let restored = try? EditorSession.load(owner.url)
            let valid = finished && failure == nil && restored?.documents[0].text == document.storage.string
            ok = ok && valid
            rows.append(["phase": phase, "elapsed_ms": elapsed, "cpu_ms": cpu(after) - cpu(before),
                "process_peak_rss_bytes": after.ru_maxrss, "snapshot_bytes": (try? Data(contentsOf: owner.url).count) ?? 0, "ok": valid])
        }
        let result: [String: Any] = ["ok": ok, "utf16_units": document.storage.length, "samples": rows,
            "measurement_scope": "capture, background encoding, atomic write and completion; verification excluded from timed interval",
            "memory_scope": "fresh-process cumulative rusage RSS peak; includes fixture and document; no child processes",
            "cold_scope": "first write in fresh process; no filesystem cache flush",
            "gui_scroll_and_input_latency": "unmeasured by this probe"]
        print(String(decoding: try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
        var completed = false
        owner.discard { _ in completed = true }
        while !completed { RunLoop.current.run(until: Date().addingTimeInterval(0.001)) }
        return ok ? 0 : 1
    }
}
