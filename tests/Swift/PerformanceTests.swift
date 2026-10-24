import AppKit
import Darwin

/// Explicit native performance workload; excluded from release and normal tests.
enum PerformanceTests {
    @MainActor private final class Heartbeat {
        var maxLag = 0.0
        var lastTick = ProcessInfo.processInfo.systemUptime
        func tick() {
            let now = ProcessInfo.processInfo.systemUptime
            maxLag = max(maxLag, max(0, now - lastTick - 0.02) * 1000)
            lastTick = now
        }
    }
    private final class WeakObject {
        weak var value: AnyObject?
        init(_ value: AnyObject) { self.value = value }
    }

    private static func resources() -> [String: Double] {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return ["cpu_ms": Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000 + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000,
                "peak_rss_bytes": Double(usage.ru_maxrss),
                "footprint_bytes": result == KERN_SUCCESS ? Double(info.phys_footprint) : -1,
                "resident_bytes": result == KERN_SUCCESS ? Double(info.resident_size) : -1]
    }

    @MainActor static func run(app: EditorAppDelegate, directory: URL, scenario: String, bytes: Int) async -> Int32 {
        let cycles = max(1, Int(ProcessInfo.processInfo.environment["SOURCE_EDITOR_PERF_CYCLES"] ?? "") ?? 4)
        var rows: [[String: Any]] = []
        var failed: [String] = []
        let heartbeatState = Heartbeat()
        let heartbeat = Timer(timeInterval: 0.02, repeats: true) { _ in
            MainActor.assumeIsolated { heartbeatState.tick() }
        }
        RunLoop.main.add(heartbeat, forMode: .common)
        defer { heartbeat.invalidate() }
        func check(_ name: String, _ value: Bool) { if !value { failed.append(name) } }
        func pump(_ seconds: Double = 0.15) async {
            if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: NSApp.keyWindow?.windowNumber ?? 0,
                context: nil, subtype: 0, data1: 0, data2: 0) { NSApp.postEvent(event, atStart: false) }
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        func snapshot(_ name: String, extra: [String: Any] = [:]) {
            var row: [String: Any] = resources()
            row["phase"] = name
            row["max_heartbeat_delay_ms"] = heartbeatState.maxLag
            row.merge(extra) { _, new in new }
            rows.append(row)
            print("PERF " + name)
            fflush(stdout)
        }
        func measured(_ name: String, operation: () -> Void) {
            let before = resources(), started = ProcessInfo.processInfo.systemUptime
            autoreleasepool { operation() }
            var row: [String: Any] = resources()
            row["phase"] = name
            row["elapsed_ms"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
            row["operation_cpu_ms"] = (resources()["cpu_ms"] ?? 0) - (before["cpu_ms"] ?? 0)
            rows.append(row)
            print("PERF " + name)
            fflush(stdout)
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let line = "let value = 12345 // Unicode 中文 😀 and a realistic source line\n"
            let body = String(repeating: line, count: max(1, bytes / line.utf8.count))
            let source = scenario == "comment" ? "/*\n" + body + "*/\n" : body
            let fixture = directory.appendingPathComponent("fixture.swift")
            try Data(source.utf8).write(to: fixture)
            let workspace = app.newWindow()
            workspace.window.setContentSize(NSSize(width: 1220, height: 810))
            await pump(0.3)
            snapshot("empty_window", extra: ["fixture_bytes": source.utf8.count])
            if scenario == "file" || scenario == "comment" {
                var document: EditorDocument?
                measured("read_decode_storage") { document = try? EditorDocument.open(fixture) }
                check("strict UTF-8 read", document?.storage.string == source)
                snapshot("storage_open")
                weak var released = document
                document = nil
                await pump()
                check("storage document released", released == nil)
                snapshot("storage_closed")
                let started = ProcessInfo.processInfo.systemUptime
                measured("native_open") { workspace.openDocument(fixture) }
                workspace.window.contentView?.layoutSubtreeIfNeeded()
                workspace.window.displayIfNeeded()
                await pump(0.4)
                snapshot("open_settled", extra: ["open_to_settled_ms": (ProcessInfo.processInfo.systemUptime - started) * 1000])
                check("native file contents", workspace.currentDocument?.storage.string == source)
                if let text = workspace.currentTextView, let scroll = text.enclosingScrollView {
                    let checkComment = scenario == "comment" && text.string.utf16.count <= 2_000_000
                    let commentColor = text.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) as? NSColor
                    if checkComment { check("multiline comment starts highlighted", commentColor != nil) }
                    measured("caret_eof") { text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0)) }
                    await pump()
                    measured("edit_eof") { text.insertText("edited", replacementRange: text.selectedRange()) }
                    await pump(0.2)
                    snapshot("edit_settled")
                    measured("undo_eof") { text.undoManager?.undo() }
                    await pump(0.2)
                    check("native edit undo restores bytes", workspace.currentDocument?.storage.string == source)
                    snapshot("scroll_extent", extra: ["document_height": text.frame.height,
                        "viewport_height": scroll.contentView.bounds.height])
                    if bytes >= 65536 { check("full document scroll extent", text.frame.height > scroll.contentView.bounds.height * 2) }
                    for step in 1...20 {
                        measured("scroll_\(step)") {
                            let y = max(0, text.frame.height - scroll.contentView.bounds.height) * CGFloat(step % 10) / 9
                            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                            scroll.reflectScrolledClipView(scroll.contentView)
                            workspace.window.contentView?.layoutSubtreeIfNeeded()
                            workspace.window.displayIfNeeded()
                        }
                        await pump(scenario == "comment" ? 0.08 : 0.03)
                        if checkComment, let layout = text.layoutManager, let container = text.textContainer {
                            let visible = text.visibleRect.offsetBy(dx: -text.textContainerOrigin.x, dy: -text.textContainerOrigin.y)
                            let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
                            let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                            if characters.location < text.string.utf16.count - 3 {
                                let color = layout.temporaryAttribute(.foregroundColor, atCharacterIndex: characters.location, effectiveRange: nil) as? NSColor
                                check("multiline comment scroll \(step) highlighted", color == commentColor)
                            }
                        }
                    }
                    snapshot("scroll_settled")
                    measured("jump_eof") { text.scrollRangeToVisible(NSRange(location: text.string.utf16.count, length: 0)) }
                    await pump(0.15)
                    if let layout = text.layoutManager, let container = text.textContainer {
                        let visible = text.visibleRect.offsetBy(dx: -text.textContainerOrigin.x, dy: -text.textContainerOrigin.y)
                        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
                        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                        check("EOF scroll visible", NSMaxRange(characters) >= text.string.utf16.count - 1)
                    }
                }
                measured("close_file") { _ = workspace.executeCommand("close_tab") }
                await pump(0.3)
                snapshot("file_closed")
                measured("reopen_same_file") { workspace.openDocument(fixture) }
                await pump(0.4)
                snapshot("reopen_settled")
            } else {
                var documents: [WeakObject] = [], storages: [WeakObject] = [], views: [WeakObject] = [], layouts: [WeakObject] = []
                for cycle in 1...cycles {
                    measured("cycle_\(cycle)_open") {
                        for index in 0..<8 {
                            let url = directory.appendingPathComponent("cycle-\(cycle)-\(index).txt")
                            try? Data(source.utf8).write(to: url)
                            workspace.openDocument(url)
                            if let document = workspace.currentDocument, let view = workspace.currentTextView {
                                documents.append(WeakObject(document)); storages.append(WeakObject(document.storage))
                                views.append(WeakObject(view))
                                if let layout = view.layoutManager { layouts.append(WeakObject(layout)) }
                                if scenario == "undo" {
                                    document.setTextUndoably(source + "edited", actionName: "Performance fixture")
                                    document.checkpoint()
                                }
                            }
                        }
                    }
                    await pump(0.25)
                    snapshot("cycle_\(cycle)_opened", extra: ["documents": workspace.documents.count,
                        "attached_layout_managers": workspace.documents.reduce(0) { $0 + $1.storage.layoutManagers.count }])
                    measured("cycle_\(cycle)_switch") {
                        for index in 1..<workspace.documents.count { workspace.selectDocument(index) }
                    }
                    measured("cycle_\(cycle)_close") {
                        while workspace.documents.count > 1 {
                            workspace.selectDocument(workspace.documents.count - 1)
                            _ = workspace.executeCommand("close_tab")
                        }
                    }
                    await pump(0.5)
                    let counts = ["closed_documents_alive": documents.filter { $0.value != nil }.count,
                                  "closed_storage_alive": storages.filter { $0.value != nil }.count,
                                  "closed_views_alive": views.filter { $0.value != nil }.count,
                                  "closed_layouts_alive": layouts.filter { $0.value != nil }.count]
                    snapshot("cycle_\(cycle)_closed", extra: counts)
                    for (kind, count) in counts { check("\(kind) cycle \(cycle)", count == 0) }
                }
            }
            for document in workspace.documents { document.checkpoint() }
            workspace.window.performClose(nil)
            await pump(0.3)
            snapshot("window_closed")
        } catch { failed.append(String(describing: error)) }
        let report: [String: Any] = ["scenario": scenario, "requested_bytes": bytes, "cycle_count": ["file", "comment"].contains(scenario) ? 0 : cycles, "failed": failed,
            "rows": rows, "max_heartbeat_delay_ms": heartbeatState.maxLag,
            "scope": "native AppKit window, storage read/open, caret and programmatic viewport scrolling; no real wheel/inertia or GPU frame measurement",
            "memory_scope": "current process footprint/resident and cumulative RSS high water; object probes are weak references",
            "cache_scope": "fresh process per scenario; reopen uses the same process and file; filesystem cache is not flushed"]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("metrics.json"))
        return failed.isEmpty ? 0 : 1
    }
}
