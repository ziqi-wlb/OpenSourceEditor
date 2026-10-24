import AppKit

enum ContextMenuUITests {
    @MainActor static func run(delegate: EditorWorkspace, directory: URL) async -> (passed: Int, failed: Int) {
        var passed = 0, failed = 0
        func check(_ name: String, _ value: Bool) {
            if value { passed += 1; print("PASS \(name)") }
            else { failed += 1; print("FAIL \(name)") }
        }
        func pump(_ seconds: Double = 0.08) async {
            if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: delegate.window.windowNumber,
                context: nil, subtype: 0, data1: 0, data2: 0) { NSApp.postEvent(event, atStart: false) }
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        func key(_ text: String, code: UInt16) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: NSApp.modalWindow?.windowNumber ?? delegate.window.windowNumber,
                    context: nil, characters: text, charactersIgnoringModifiers: text.lowercased(), isARepeat: false, keyCode: code) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
        }
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        func menu(for view: NSView, point: NSPoint? = nil) -> NSMenu? {
            let local = point ?? NSPoint(x: view.bounds.midX, y: view.bounds.midY)
            guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: view.convert(local, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: delegate.window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return nil }
            return view.menu(for: event)
        }
        @discardableResult func invoke(_ title: String, in menu: NSMenu?) -> Bool {
            guard let item = menu?.items.first(where: { $0.title == title }), item.isEnabled, let action = item.action else { return false }
            return NSApp.sendAction(action, to: item.target, from: item)
        }
        func tab(_ document: EditorDocument) -> NSView? {
            guard let index = delegate.documents.firstIndex(where: { $0 === document }) else { return nil }
            return delegate.window.contentView.map(descendants)?.compactMap { $0 as? NSButton }.first {
                $0.tag == index && $0.title == (document.isModified ? "● " : "") + document.displayName
            }
        }
        func popup(_ view: NSView, title: String, point: NSPoint? = nil) async -> Bool {
            let previous = delegate.lastContextMenu
            let actionBefore = delegate.snapshot["lastMenuActionID"] as? String
            let local = point ?? NSPoint(x: view.bounds.midX, y: view.bounds.midY)
            for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: view.convert(local, to: nil), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: delegate.window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1) { NSApp.postEvent(event, atStart: false) }
            }
            let deadline = Date().addingTimeInterval(2)
            while delegate.lastContextMenu === previous, Date() < deadline { await pump(0.03) }
            guard let actual = delegate.lastContextMenu, actual !== previous,
                  let target = actual.items.firstIndex(where: { $0.title == title && $0.isEnabled }) else {
                key("\u{1b}", code: 53); await pump(); return false
            }
            await pump(0.1)
            for _ in 0..<40 {
                if actual.highlightedItem?.title == title { break }
                let index = actual.highlightedItem.flatMap { item in actual.items.firstIndex { $0 === item } }
                let up = index.map { $0 > target } ?? false
                key(up ? "\u{f700}" : "\u{f701}", code: up ? 126 : 125)
                await pump(0.025)
            }
            guard actual.highlightedItem?.title == title else {
                key("\u{1b}", code: 53); await pump(); return false
            }
            // Capture only this process's native menu window, never the desktop.
            if let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
               let own = windows.filter({ ($0[kCGWindowOwnerPID as String] as? Int) == Int(getpid()) && ($0[kCGWindowLayer as String] as? Int ?? 0) > 0 }).max(by: {
                   let a = $0[kCGWindowBounds as String] as? [String: Any] ?? [:]
                   let b = $1[kCGWindowBounds as String] as? [String: Any] ?? [:]
                   return (a["Width"] as? Double ?? 0) * (a["Height"] as? Double ?? 0) <
                       (b["Width"] as? Double ?? 0) * (b["Height"] as? Double ?? 0)
               }), let number = own[kCGWindowNumber as String] as? UInt32,
               let image = CGWindowListCreateImage(.null, .optionIncludingWindow, number, [.boundsIgnoreFraming, .bestResolution]),
               let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try? data.write(to: directory.appendingPathComponent("context-\(actual.title == "Editor" ? "editor" : view is NSOutlineView ? "sidebar" : "tab").png"))
            }
            key("\r", code: 36)
            let finished = Date().addingTimeInterval(2)
            while delegate.snapshot["lastMenuActionID"] as? String == actionBefore, Date() < finished { await pump(0.03) }
            let success = delegate.snapshot["lastMenuActionID"] as? String != actionBefore
            if !success { key("\u{1b}", code: 53); await pump() }
            return success
        }
        func waitSheet() async -> NSWindow? {
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                if let sheet = delegate.window.attachedSheet, sheet.isVisible { return sheet }
                await pump(0.03)
            }
            return nil
        }
        let session = delegate.sessionSnapshot
        let clipboard = NSPasteboard.general.pasteboardItems?.map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        } ?? []
        defer {
            NSPasteboard.general.clearContents()
            let items = clipboard.map { values -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { NSPasteboard.general.writeObjects(items) }
        }
        do {
            for document in delegate.documents { document.checkpoint() }
            let project = directory.appendingPathComponent("context project", isDirectory: true)
            let nested = project.appendingPathComponent("nested 中文", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let first = nested.appendingPathComponent("file 空格's.txt")
            let second = project.appendingPathComponent("other.txt")
            try Data("one two THREE\n".utf8).write(to: first)
            try Data("other\n".utf8).write(to: second)
            delegate.openProject(EditorProject(folderURL: project))
            delegate.openDocument(first)
            let firstDocument = delegate.currentDocument!
            delegate.openDocument(second)
            let secondDocument = delegate.currentDocument!
            await pump()
            guard let firstTab = tab(firstDocument), let tabMenu = menu(for: firstTab) else {
                throw EditorFailure.invalidEdit("Missing tab context menu")
            }
            check("nonactive tab offers file and close operations", ["Copy File Path", "Save As…", "Close Other Tabs", "Close Tabs to the Right", "Close Unmodified Tabs"].allSatisfy { name in tabMenu.items.contains { $0.title == name } })
            invoke("Copy File Path", in: tabMenu)
            check("tab copies clicked file path without changing document", NSPasteboard.general.string(forType: .string) == first.path && delegate.currentDocument === secondDocument)
            invoke("Copy Relative File Path", in: tabMenu)
            check("relative path preserves nested Unicode and spaces", NSPasteboard.general.string(forType: .string) == "nested 中文/file 空格's.txt")
            invoke("Copy File Name", in: tabMenu)
            check("copy filename keeps extension and literal apostrophe", NSPasteboard.general.string(forType: .string) == first.lastPathComponent)
            invoke("Copy Folder Path", in: tabMenu)
            check("copy folder path uses clicked file parent", NSPasteboard.general.string(forType: .string) == nested.path)
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString("sentinel", forType: .string)
            let tabPopup = await popup(firstTab, title: "Copy File Path")
            check("real tab right click copies intended path", tabPopup && NSPasteboard.general.string(forType: .string) == first.path && delegate.currentDocument === secondDocument)
            invoke("Reveal in Side Bar", in: tabMenu)
            guard let outline = delegate.window.contentView.map(descendants)?.compactMap({ $0 as? NSOutlineView }).first else {
                throw EditorFailure.invalidEdit("Missing project tree")
            }
            let row = outline.selectedRow
            check("reveal expands nested folder and selects file", row >= 0 && outline.view(atColumn: 0, row: row, makeIfNecessary: true)?.toolTip == first.path && delegate.currentDocument === secondDocument)
            let rowPoint = NSPoint(x: 90, y: outline.rect(ofRow: row).midY)
            guard let sidebarMenu = menu(for: outline, point: rowPoint) else { throw EditorFailure.invalidEdit("Missing sidebar context menu") }
            invoke("Copy File Path", in: sidebarMenu)
            check("sidebar copies clicked row rather than editor file", NSPasteboard.general.string(forType: .string) == first.path && delegate.currentDocument === secondDocument)
            NSPasteboard.general.setString("sentinel", forType: .string)
            let sidebarPopup = await popup(outline, title: "Copy File Path", point: rowPoint)
            check("real sidebar right click copies intended path", sidebarPopup && NSPasteboard.general.string(forType: .string) == first.path)
            check("blank sidebar has no file context menu", menu(for: outline, point: NSPoint(x: 90, y: outline.frame.height + 100)) == nil)
            invoke("Open", in: sidebarMenu)
            check("sidebar Open selects clicked file", delegate.currentDocument === firstDocument)
            let editor = delegate.currentTextView!
            editor.setSelectedRange(NSRange(location: 0, length: 3))
            guard let editorMenu = menu(for: editor) else { throw EditorFailure.invalidEdit("Missing editor context menu") }
            check("editor offers clipboard undo indentation and transforms", ["Undo", "Redo", "Cut", "Copy", "Paste", "Delete", "Select All", "Indent", "Unindent", "Sort Lines", "Uppercase", "Lowercase"].allSatisfy { name in editorMenu.items.contains { $0.title == name } })
            NSPasteboard.general.setString("sentinel", forType: .string)
            let textPoint = NSPoint(x: editor.textContainerOrigin.x + 5, y: editor.textContainerOrigin.y + 5)
            let editorPopup = await popup(editor, title: "Copy", point: textPoint)
            check("real editor right click copies selected text", editorPopup && NSPasteboard.general.string(forType: .string) == "one")
            check("context path copy preserves selected text and clean state", invoke("Copy File Path", in: menu(for: editor)) && editor.selectedRange() == NSRange(location: 0, length: 3) && !firstDocument.isModified && NSPasteboard.general.string(forType: .string) == first.path)
            invoke("Cut", in: menu(for: editor)); await pump()
            check("context Cut changes correct buffer", firstDocument.storage.string == " two THREE\n" && firstDocument.isModified)
            invoke("Undo", in: menu(for: editor)); await pump()
            check("context Undo restores text and selection", firstDocument.storage.string == "one two THREE\n" && editor.selectedRange() == NSRange(location: 0, length: 3))
            invoke("Redo", in: menu(for: editor)); await pump()
            check("context Redo repeats cut", firstDocument.storage.string == " two THREE\n")
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString("one", forType: .string)
            invoke("Paste", in: menu(for: editor)); await pump()
            check("context Paste inserts plain clipboard text", firstDocument.storage.string == "one two THREE\n")
            editor.setSelectedRange(NSRange(location: 8, length: 5)); invoke("Lowercase", in: menu(for: editor)); await pump()
            check("context lowercase shares editing operation", firstDocument.storage.string == "one two three\n")
            invoke("Select All", in: menu(for: editor))
            check("context Select All selects complete document", editor.selectedRange() == NSRange(location: 0, length: (editor.string as NSString).length))
            invoke("Indent", in: menu(for: editor)); await pump()
            check("context indent uses document settings", firstDocument.storage.string == "\tone two three\n")
            invoke("Unindent", in: menu(for: editor)); await pump()
            check("context unindent reverses indentation", firstDocument.storage.string == "one two three\n")
            editor.selectedRanges = [NSValue(range: NSRange(location: 0, length: 3)), NSValue(range: NSRange(location: 4, length: 3))]
            invoke("Copy", in: menu(for: editor))
            print("DETAIL multiple Copy text=\(editor.string.debugDescription) ranges=\(editor.selectedRanges) clipboard=\(NSPasteboard.general.string(forType: .string)?.debugDescription ?? "nil")")
            check("multiple selection Copy includes every region", NSPasteboard.general.string(forType: .string) == "one\ntwo")
            invoke("Delete", in: menu(for: editor)); await pump()
            check("multiple selection Delete edits every region", firstDocument.storage.string == "  three\n")
            invoke("Undo", in: menu(for: editor)); await pump()
            check("multiple selection undo restores regions", firstDocument.storage.string == "one two three\n" && editor.selectedRanges.count == 2)
            NSPasteboard.general.setString("X", forType: .string)
            invoke("Paste", in: menu(for: editor)); await pump()
            check("multiple selection Paste replaces every region", firstDocument.storage.string == "X X three\n")
            invoke("Undo", in: menu(for: editor)); await pump()
            check("multiple selection Paste has one undo with restored selections", firstDocument.storage.string == "one two three\n" && editor.selectedRanges.map(\.rangeValue) == [NSRange(location: 0, length: 3), NSRange(location: 4, length: 3)])
            invoke("Cut", in: menu(for: editor)); await pump()
            check("multiple selection Cut copies and removes every region", firstDocument.storage.string == "  three\n" && NSPasteboard.general.string(forType: .string) == "one\ntwo")
            invoke("Undo", in: menu(for: editor)); await pump()
            check("multiple selection Cut has one undo with restored selections", firstDocument.storage.string == "one two three\n" && editor.selectedRanges.map(\.rangeValue) == [NSRange(location: 0, length: 3), NSRange(location: 4, length: 3)])
            firstDocument.checkpoint()
            delegate.openDocument(second)
            check("main File menu exposes path actions", NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu?.items.contains { $0.title == "Copy File Path" } == true)
            _ = delegate.executeCommand("copy_path")
            check("shared copy_path command uses current file", NSPasteboard.general.string(forType: .string) == second.path)
            let outside = directory.appendingPathComponent("context project sibling.txt")
            check("relative path rejects sibling string prefix", FilePathFormat.relative.string(for: outside, project: project) == nil)
            check("relative root is dot and non-file URL is rejected", FilePathFormat.relative.string(for: project, project: project) == "." && FilePathFormat.absolute.string(for: URL(string: "https://example.test/file")!, project: project) == nil)
            let rootPoint = NSPoint(x: 90, y: outline.rect(ofRow: 0).midY)
            let folderMenu = menu(for: outline, point: rootPoint)
            invoke("Copy File Path", in: folderMenu)
            check("folder context copies directory itself", NSPasteboard.general.string(forType: .string) == project.path && folderMenu?.items.contains { $0.title == "Open" } == false)
            // File save targets an inactive tab and restores current focus.
            firstDocument.setTextUndoably("saved by tab menu\n", actionName: "Fixture")
            let savingMenu = tab(firstDocument).flatMap { menu(for: $0) }
            invoke("Save", in: savingMenu)
            check("nonactive tab Save writes intended file and restores active tab", (try? Data(contentsOf: first)) == Data("saved by tab menu\n".utf8) && delegate.currentDocument === secondDocument && !firstDocument.isModified)
            // Retained menu actions resolve document identity after earlier indices shift.
            let staleMenu = tab(firstDocument).flatMap { menu(for: $0) }
            delegate.selectDocument(0); _ = delegate.executeCommand("close_tab")
            invoke("Close Tab", in: staleMenu)
            check("tab close follows file identity after index shift", !delegate.documents.contains { $0 === firstDocument } && delegate.documents.contains { $0 === secondDocument })
            let count = delegate.documents.count
            invoke("Close Tab", in: staleMenu)
            check("stale closed tab action cannot close a different file", delegate.documents.count == count)
            let anchorURL = project.appendingPathComponent("anchor.txt")
            let rightURL = project.appendingPathComponent("right.txt")
            try Data("anchor\n".utf8).write(to: anchorURL)
            try Data("right\n".utf8).write(to: rightURL)
            delegate.openDocument(anchorURL); let anchor = delegate.currentDocument!
            delegate.openDocument(rightURL); let right = delegate.currentDocument!
            invoke("Close Tabs to the Right", in: tab(anchor).flatMap { menu(for: $0) })
            check("Close Right keeps clicked anchor and left tabs", delegate.currentDocument === anchor && !delegate.documents.contains { $0 === right } && delegate.documents.contains { $0 === secondDocument })
            delegate.openDocument(rightURL); let dirtyRight = delegate.currentDocument!
            dirtyRight.setTextUndoably("keep dirty", actionName: "Fixture")
            let othersMenu = tab(anchor).flatMap { menu(for: $0) }
            let trigger = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 80, NSApp.modalWindow == nil else { return event }
                invoke("Close Other Tabs", in: othersMenu)
                return nil
            }
            key("\u{f716}", code: 80)
            if await waitSheet() != nil { key("\u{1b}", code: 53) }
            let closedDeadline = Date().addingTimeInterval(2)
            while delegate.window.attachedSheet != nil, Date() < closedDeadline { await pump(0.03) }
            if let trigger { NSEvent.removeMonitor(trigger) }
            check("Close Others cancellation protects dirty and remaining tabs", dirtyRight.isModified && delegate.documents.contains { $0 === dirtyRight } && delegate.documents.contains { $0 === secondDocument } && delegate.currentDocument === anchor)
            dirtyRight.checkpoint()
            invoke("Close Other Tabs", in: tab(anchor).flatMap { menu(for: $0) })
            check("Close Others leaves only clicked anchor", delegate.documents.count == 1 && delegate.currentDocument === anchor)
            anchor.setTextUndoably("anchor dirty", actionName: "Fixture")
            delegate.openDocument(rightURL)
            invoke("Close Unmodified Tabs", in: tab(anchor).flatMap { menu(for: $0) })
            check("Close Unmodified retains unsaved text", delegate.documents.count == 1 && delegate.currentDocument === anchor && anchor.isModified)
            anchor.checkpoint(); _ = delegate.executeCommand("new_file")
            let unnamed = delegate.currentTextView!
            let unnamedMenu = menu(for: unnamed)
            check("untitled path actions disabled", unnamedMenu?.items.first { $0.title == "Copy File Path" }?.isEnabled == false && unnamedMenu?.items.first { $0.title == "Copy Relative File Path" }?.isEnabled == false)
            NSPasteboard.general.setString("retain clipboard", forType: .string)
            _ = delegate.executeCommand("copy_path")
            check("untitled copy path does not clear clipboard", NSPasteboard.general.string(forType: .string) == "retain clipboard")
        } catch { check("context menu workflow", false); print("DETAIL context error \(error)") }
        if let sheet = NSApp.modalWindow, sheet.sheetParent === delegate.window { NSApp.abortModal(); await pump() }
        for document in delegate.documents { document.checkpoint() }
        check("context menus restore original session", delegate.restoreSession(session))
        print("Context menu UI tests: \(passed) passed, \(failed) failed")
        return (passed, failed)
    }
}
