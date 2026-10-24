import AppKit

enum DailyUITests {
    @MainActor static func run(directory: URL) async -> Int32 {
        fputs("DAILY: starting\n", stderr)
        var passed = 0, failures: [String] = [], metrics: [String: Double] = [:]
        func check(_ name: String, _ value: Bool) { fputs("DAILY CHECK: " + name + "\n", stderr); if value { passed += 1 } else { failures.append(name); print("FAIL: " + name) } }
        func pump(_ seconds: Double = 0.1) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        func wait(_ condition: () -> Bool, timeout: Double = 6) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline { if condition() { return true }; await pump(0.05) }
            return condition()
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let project = directory.appendingPathComponent("project"); try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let md = project.appendingPathComponent("note.md"), plain = project.appendingPathComponent("code.txt")
            try "# Original\n- [ ] task\n".write(to: md, atomically: true, encoding: .utf8)
            try "original disk".write(to: plain, atomically: true, encoding: .utf8)
            let store = EditorDesktopStore(directory: directory.appendingPathComponent("state"))
            let app = EditorAppDelegate(recentFiles: RecentFiles(defaults: nil), desktopStore: store)
            let workspace = app.newWindow(openURLs: [md, plain], projectURL: project, tabbed: false)
            workspace.selectDocument(0)
            let document = workspace.currentDocument!
            var config = EditorConfiguration(); config.fontSize = 16; config.theme = "light"; config.tabSize = 2
            workspace.applyConfiguration(config)
            workspace.currentTextView!.setSelectedRange(.init(location: 2, length: 3))
            workspace.setMarkdownMode(.sideBySide)
            fputs("DAILY: workspace created\n", stderr)
            let saved = workspace.desktopSnapshot
            document.setTextUndoably("DISCARDED UNSAVED TEXT", actionName: "Fixture")
            app.persistDesktop()
            let stateText = try String(contentsOf: store.directory.appendingPathComponent("workspace.json"), encoding: .utf8)
            check("Normal desktop never stores discarded text", !stateText.contains("DISCARDED") && !stateText.contains("Original"))
            try "# Current disk\n- [ ] task\n".write(to: md, atomically: true, encoding: .utf8)
            try store.saveDesktop(.init(workspaces: [saved]))
            let restarted = EditorAppDelegate(recentFiles: RecentFiles(defaults: nil), desktopStore: store)
            restarted.launch(openURLs: [], projectURL: nil)
            fputs("DAILY: restored launch returned\n", stderr)
            let restored = restarted.activeWorkspace!
            check("Launch reads persisted file order", restored.documents.compactMap(\.fileURL) == [md, plain])
            check("Launch reads current disk, not dirty snapshot", restored.currentDocument?.storage.string == "# Current disk\n- [ ] task\n" && restored.currentDocument?.isModified == false)
            check("Launch restores selection and Markdown mode", restored.currentTextView?.selectedRange() == .init(location: 2, length: 3) && restored.markdownViewMode == .sideBySide)
            check("Launch restores preferences and project", restored.currentTextView?.font?.pointSize == 16 && restored.snapshot["theme"] as? String == "light" && restored.snapshot["projectRoot"] as? String == project.path)
            restored.window.close()
            await pump(0.2) // Let AppKit/WebKit complete window teardown before the next native event.
            fputs("DAILY: restored checks finished\n", stderr)
            workspace.setMarkdownMode(.edit)
            await pump(0.1)
            fputs("DAILY: source view active\n", stderr)
            let view = workspace.currentTextView!
            workspace.window.makeFirstResponder(view)
            document.setTextUndoably("- [x] 中文😀", actionName: "Fixture")
            document.undoManager.removeAllActions()
            fputs("DAILY: Enter fixture ready\n", stderr)
            view.setSelectedRange(.init(location: document.storage.length, length: 0))
            let selection = view.selectedRange()
            document.undoManager.beginUndoGrouping(); view.insertNewline(nil); document.undoManager.endUndoGrouping()
            fputs("DAILY: Enter returned\n", stderr)
            check("Native Enter continues task", document.storage.string == "- [x] 中文😀\n- [ ] ")
            document.undoManager.undo()
            await pump(0.1)
            fputs("DAILY: Enter undo returned\n", stderr)
            check("Native Enter single undo restores selection", document.storage.string == "- [x] 中文😀" && view.selectedRange() == selection && !document.undoManager.canUndo)
            fputs("DAILY: task fixture entering\n", stderr)
            document.setTextUndoably("- [ ] task", actionName: "Fixture"); document.undoManager.removeAllActions()
            fputs("DAILY: task fixture finished\n", stderr)
            view.setSelectedRange(.init(location: 0, length: document.storage.length))
            fputs("DAILY: task command entering\n", stderr)
            _ = workspace.executeCommand("markdown_task")
            fputs("DAILY: task command finished\n", stderr)
            check("Task command reaches source", document.storage.string == "- [x] task")
            document.undoManager.undo()
            await pump(0.1)
            fputs("DAILY: task undo finished\n", stderr)
            check("Task command has one undo", document.storage.string == "- [ ] task" && !document.undoManager.canUndo)
            document.setTextUndoably("中文😀", actionName: "Fixture"); document.undoManager.removeAllActions()
            view.setSelectedRange(.init(location: 0, length: document.storage.length))
            _ = workspace.executeCommand("markdown_bold")
            await pump(0.1)
            check("Formatting keeps selected text", document.storage.string == "**中文😀**" && view.selectedRange() == .init(location: 2, length: 4))
            document.undoManager.undo()
            await pump(0.1)
            check("Formatting undo", document.storage.string == "中文😀")
            document.undoManager.redo(); await pump(0.1)
            check("Formatting redo restores text and selection", document.storage.string == "**中文😀**" && view.selectedRange() == .init(location: 2, length: 4))
            document.undoManager.undo(); await pump(0.1)
            view.setSelectedRange(.init(location: document.storage.length, length: 0))
            let beforeImage = document.storage.string
            fputs("DAILY: image paste entering\n", stderr)
            workspace.insertNoteImage(DailyFeatureTests.pixel)
            fputs("DAILY: image paste finished\n", stderr)
            await pump(0.1)
            check("Image paste entry inserts relative link", document.storage.string.contains("![image](assets/image-"))
            let images = try FileManager.default.contentsOfDirectory(at: project.appendingPathComponent("assets"), includingPropertiesForKeys: nil)
            check("Image paste creates actual PNG", images.count == 1 && CGImageSourceCreateWithURL(images[0] as CFURL, nil) != nil)
            document.undoManager.undo()
            await pump(0.1)
            check("Image undo removes link, keeps attachment", document.storage.string == beforeImage && FileManager.default.fileExists(atPath: images[0].path))
            _ = workspace.executeCommand("note_meeting")
            check("Meeting template is editable Markdown", workspace.currentDocument?.storage.string.contains("## Action Items") == true && workspace.currentDocument?.syntaxIdentifier == "md" && workspace.currentDocument?.isModified == true)
            check("Notes menu exposed", NSApp.mainMenu?.items.contains(where: { $0.title == "Notes" }) == true)
            workspace.selectDocument(0)
            fputs("DAILY: notes finished\n", stderr)
            let outside = directory.appendingPathComponent("outside.txt"); try "outside remains".write(to: outside, atomically: true, encoding: .utf8)
            let link = project.appendingPathComponent("outside-link.txt")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            let trashedLink = try workspace.trashProjectItem(link)
            check("Trash symlink leaves target intact", (try? String(contentsOf: outside, encoding: .utf8)) == "outside remains" && !FileManager.default.fileExists(atPath: link.path))
            if let trashedLink { try FileManager.default.removeItem(at: trashedLink) }
            let renamed = project.appendingPathComponent("renamed.md")
            document.setTextUndoably(document.storage.string + " dirty", actionName: "Before Rename")
            let beforeRename = document.storage.string
            try workspace.moveProjectItem(md, to: renamed)
            check("Rename preserves dirty buffer and disk identity", document.fileURL == renamed && document.storage.string == beforeRename && document.isModified)
            document.undoManager.undo()
            await pump(0.1)
            check("Rename retains undo", document.storage.string != beforeRename)
            let folder = try workspace.createProjectItem(in: project, name: "folder", directory: true)
            let nested = folder.appendingPathComponent("nested.txt"); try "nested".write(to: nested, atomically: true, encoding: .utf8)
            let other = app.newWindow(openURLs: [nested], tabbed: false)
            let otherDocument = other.currentDocument!
            otherDocument.setTextUndoably("dirty nested", actionName: "Fixture")
            let moved = project.appendingPathComponent("moved")
            try workspace.moveProjectItem(folder, to: moved)
            check("Directory move updates all windows", otherDocument.fileURL == moved.appendingPathComponent("nested.txt") && otherDocument.storage.string == "dirty nested")
            do { try workspace.moveProjectItem(renamed, to: plain); check("Collision rejected", false) }
            catch { check("Collision preserves buffer path", document.fileURL == renamed && FileManager.default.fileExists(atPath: plain.path)) }
            let trashed = try workspace.trashProjectItem(moved)
            check("Trash preserves dirty open buffer as untitled", otherDocument.fileURL == nil && otherDocument.storage.string == "dirty nested" && otherDocument.isModified)
            check("Trash returns actual location", trashed.map { FileManager.default.fileExists(atPath: $0.path) } == true)
            if let trashed { try FileManager.default.removeItem(at: trashed) } // Only the returned owned fixture.
            other.window.close()

            workspace.selectDocument(1)
            let clean = workspace.currentDocument!
            let standalone = directory.appendingPathComponent("standalone.txt")
            try "before restore".write(to: standalone, atomically: true, encoding: .utf8)
            let monitorOnly = app.newWindow(tabbed: false)
            monitorOnly.startFileMonitoring()
            var standaloneState = saved
            standaloneState.projectPath = nil
            standaloneState.files = [.init(path: standalone.path, settings: .init(), encoding: .utf8, selections: [[0, 0]], markdownMode: "edit")]
            standaloneState.selectedPath = standalone.path
            monitorOnly.restoreDesktop(standaloneState)
            await pump(0.8)
            try "after restore".write(to: standalone, atomically: true, encoding: .utf8)
            check("Restore without project refreshes monitored file parents", await wait { monitorOnly.currentDocument?.storage.string == "after restore" })
            monitorOnly.window.close()
            fputs("DAILY: file operations finished\n", stderr)
            workspace.startFileMonitoring()
            await pump(0.9)
            let changedAt = ProcessInfo.processInfo.systemUptime
            try "external clean reload 😀".write(to: plain, atomically: true, encoding: .utf8)
            let reloaded = await wait { clean.storage.string == "external clean reload 😀" }
            metrics["external_clean_reload_seconds"] = ProcessInfo.processInfo.systemUptime - changedAt
            check("Actual FSEvents reloads atomic save", reloaded && !clean.isModified && !clean.undoManager.canUndo)
            check("Reload selection remains valid", TextOperations.valid(clean.storage.string, workspace.currentTextView!.selectedRanges.map(\.rangeValue)))
            clean.setTextUndoably("unsaved buffer", actionName: "Fixture")
            try "second external version".write(to: plain, atomically: true, encoding: .utf8)
            check("Dirty external change has visible review", await wait { workspace.snapshot["diskChangeCount"] as? Int == 1 && (workspace.snapshot["notice"] as? String)?.contains("unsaved") == true })
            check("Dirty external change never overwrites", clean.storage.string == "unsaved buffer" && clean.undoManager.canUndo)
            let added = project.appendingPathComponent("added.txt"); try "new".write(to: added, atomically: true, encoding: .utf8)
            check("Native file event refreshes project index", await wait { workspace.snapshot["projectFiles"] as? Int == 4 })
            try FileManager.default.removeItem(at: plain)
            check("Deletion yields missing-file notice", await wait { (workspace.snapshot["notice"] as? String)?.contains("moved or deleted") == true })
            check("Deleted file text retained", clean.storage.string == "unsaved buffer")

            fputs("DAILY: monitoring finished\n", stderr)
            _ = workspace.executeCommand("find")
            let controls = descendants(workspace.window.contentView!)
            let search = controls.compactMap { $0 as? NSSearchField }.first!
            let regex = controls.compactMap { $0 as? NSButton }.first { $0.toolTip == "Use regular expressions" }!
            clean.setTextUndoably(String(repeating: "a", count: 10000) + "!", actionName: "Fixture")
            search.stringValue = "(a+)+$"; regex.state = .on
            workspace.controlTextDidChange(Notification(name: NSText.didChangeNotification, object: search))
            await pump(0.2) // The 150 ms debounce has elapsed; ICU is running now.
            check("Pathological query still running during UI tick", workspace.snapshot["findMessage"] as? String == "Searching…")
            let began = ProcessInfo.processInfo.systemUptime
            await pump(0.08)
            metrics["main_queue_tick_seconds"] = ProcessInfo.processInfo.systemUptime - began
            check("Regex work leaves main queue responsive", metrics["main_queue_tick_seconds"]! < 0.3)
            search.stringValue = "latest"; regex.state = .off
            clean.setTextUndoably("latest latest", actionName: "Fixture")
            workspace.controlTextDidChange(Notification(name: NSText.didChangeNotification, object: search))
            check("Only latest query/revision reported", await wait { workspace.snapshot["findMatches"] as? Int == 2 && workspace.snapshot["findMessage"] as? String == "2 matches" })
            clean.setTextUndoably("old", actionName: "Fixture")
            search.stringValue = "old"; workspace.controlTextDidChange(Notification(name: NSText.didChangeNotification, object: search))
            clean.setTextUndoably("latest", actionName: "Fixture")
            check("Stale matching ranges discarded", await wait { workspace.snapshot["findMessage"] as? String == "0 matches" })

            if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(workspace.window.windowNumber), [.boundsIgnoreFraming]) {
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("daily-workspace.png"))
            }
            fputs("DAILY: search finished\n", stderr)
            let noticeBeforeClose = workspace.snapshot["notice"] as? String
            workspace.window.close()
            try "late disk".write(to: plain, atomically: true, encoding: .utf8)
            await pump(1)
            check("Close stops monitor and late callbacks", workspace.snapshot["monitorActive"] as? Bool == false && workspace.snapshot["notice"] as? String == noticeBeforeClose && app.workspaces.isEmpty)
        } catch { failures.append("Unexpected: " + error.localizedDescription); print(error) }
        let output: [String: Any] = ["passed": passed, "failed": failures.count, "failures": failures, "metrics": metrics,
                                    "scope": "Native UI and actual FSEvents; restart uses a fresh injected-store app delegate, not a separate OS login; hardware IME not verified"]
        print(String(data: try! JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), encoding: .utf8)!)
        return failures.isEmpty ? 0 : 1
    }
}
