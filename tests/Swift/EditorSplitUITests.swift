import AppKit

enum EditorSplitUITests {
    @MainActor static func run(directory: URL) async -> Int32 {
        var passed = 0, failures: [String] = []
        func check(_ name: String, _ value: Bool) { if value { passed += 1 } else { failures.append(name); print("FAIL: " + name) } }
        func pump() async { try? await Task.sleep(nanoseconds: 150_000_000) }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func control<T: NSView>(_ id: String, _ workspace: EditorWorkspace, as type: T.Type) -> T? {
            let views = descendants(workspace.window.contentView!) + workspace.window.titlebarAccessoryViewControllers.flatMap { descendants($0.view) }
            return views.first { $0.identifier?.rawValue == id } as? T
        }
        func menu(_ title: String, _ workspace: EditorWorkspace) -> Bool {
            workspace.activateMenus()
            guard let item = NSApp.mainMenu?.item(withTitle: "View")?.submenu?.item(withTitle: title), let action = item.action,
                  workspace.validateMenuItem(item) else { return false }
            return NSApp.sendAction(action, to: item.target, from: item)
        }
        func capture(_ workspace: EditorWorkspace, _ name: String) throws {
            workspace.window.contentView?.layoutSubtreeIfNeeded()
            guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(workspace.window.windowNumber), [.boundsIgnoreFraming]) else { return }
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name))
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let a = directory.appendingPathComponent("first 中文.swift"), b = directory.appendingPathComponent("second.txt")
            let source = "// First 中文😀\n" + (0..<300).map { "let value\($0) = \($0)\n" }.joined()
            try source.write(to: a, atomically: true, encoding: .utf8)
            try "Second document\nIndependent editing\n".write(to: b, atomically: true, encoding: .utf8)
            let originalA = try Data(contentsOf: a), originalB = try Data(contentsOf: b)
            let app = EditorAppDelegate(recentFiles: RecentLocations(defaults: nil), desktopStore: EditorDesktopStore(directory: directory.appendingPathComponent("support")))
            let home = app.newWindow(tabbed: false)
            check("Home disables split button and menu", control("workspace.splitEditor", home, as: NSButton.self)?.isEnabled == false && !menu("Split Right", home))
            home.window.performClose(nil)
            let workspace = app.newWindow(openURLs: [a, b], projectURL: directory, tabbed: false)
            workspace.window.setContentSize(NSSize(width: 1220, height: 810))
            let normalFrame = workspace.window.frame
            workspace.selectDocument(0)
            let firstDocument = workspace.currentDocument!, secondDocument = workspace.documents[1]
            let originalView = workspace.currentTextView!
            originalView.setSelectedRange(NSRange(location: 3, length: 2))
            let split = control("workspace.splitEditor", workspace, as: NSButton.self)
            split?.performClick(nil); await pump()
            check("Titlebar button creates two real editors", workspace.paneViewsForTesting.count == 2)
            check("Splitting retains the original editor and selection", workspace.paneViewsForTesting.first === originalView && originalView.selectedRange() == NSRange(location: 3, length: 2))
            check("Both editors share the file storage without cloning", workspace.paneViewsForTesting.allSatisfy { $0.textStorage === firstDocument.storage } && firstDocument.storage.layoutManagers.count == 2)
            let mirrored = workspace.paneViewsForTesting[1]
            workspace.window.makeFirstResponder(mirrored)
            mirrored.setSelectedRange(NSRange(location: 0, length: 0))
            firstDocument.undoManager.beginUndoGrouping()
            mirrored.insertText("// edit\n", replacementRange: mirrored.selectedRange())
            firstDocument.undoManager.endUndoGrouping()
            check("Native typing in the second editor updates the first", originalView.string.hasPrefix("// edit\n") && mirrored.string == originalView.string)
            firstDocument.undoManager.undo()
            check("Shared-file undo restores one document", firstDocument.storage.string == source)
            workspace.window.makeFirstResponder(originalView)
            let chooser = control("editor.pane.1", workspace, as: NSPopUpButton.self)!
            let other = chooser.itemArray.first { ($0.representedObject as? EditorDocument) === secondDocument }!
            chooser.select(other)
            _ = NSApp.sendAction(chooser.action!, to: chooser.target, from: chooser)
            await pump()
            check("Pane file selector opens a different file", workspace.paneViewsForTesting[0].textStorage === firstDocument.storage && workspace.paneViewsForTesting[1].textStorage === secondDocument.storage)
            check("Changing the right file preserves the left view", workspace.paneViewsForTesting[0] === originalView && workspace.currentDocument === secondDocument)
            let right = workspace.paneViewsForTesting[1]
            right.setSelectedRange(NSRange(location: 7, length: 3))
            originalView.setSelectedRange(NSRange(location: 4, length: 2))
            let current = workspace.currentTextView
            workspace.selectDocument(workspace.selectedIndex)
            check("Reselecting the active tab preserves its pane and cursor", workspace.currentTextView === current && right.selectedRange() == NSRange(location: 7, length: 3))
            workspace.window.makeFirstResponder(originalView)
            check("Native focus routes the active document to the left file", workspace.currentDocument === firstDocument && workspace.currentTextView === originalView)
            check("Focus updates the represented file and syntax", workspace.window.representedURL == a.standardizedFileURL.resolvingSymlinksInPath() && workspace.snapshot["syntax"] as? String == "Swift")
            check("View menu focuses the next pane", menu("Focus Next Pane", workspace) && workspace.currentDocument === secondDocument && workspace.currentTextView === right)
            workspace.activateMenus()
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.option, .command], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: workspace.window.windowNumber, context: nil, characters: "3", charactersIgnoringModifiers: "3", isARepeat: false, keyCode: 20) {
                check("Native pane shortcut routes through the menu", NSApp.mainMenu?.performKeyEquivalent(with: event) == true && workspace.currentDocument === firstDocument)
            }
            originalView.scroll(NSPoint(x: 0, y: 600)); await pump()
            let leftScroll = originalView.enclosingScrollView!.contentView.bounds.origin.y
            check("Pane scrolling is independent", leftScroll > 300 && right.enclosingScrollView!.contentView.bounds.origin.y == 0)
            let before = workspace.paneViewsForTesting
            check("Split Down works through the native menu", menu("Split Down", workspace))
            workspace.window.contentView?.layoutSubtreeIfNeeded(); await pump()
            check("Top and bottom use real nonoverlapping geometry", before[1].enclosingScrollView!.frame.minY > before[0].enclosingScrollView!.frame.maxY && abs(before[0].enclosingScrollView!.frame.width - before[1].enclosingScrollView!.frame.width) < 1)
            check("Orientation changes reuse both editors and selections", workspace.paneViewsForTesting[0] === before[0] && workspace.paneViewsForTesting[1] === before[1] && right.selectedRange() == NSRange(location: 7, length: 3))
            try capture(workspace, "split-rows.png")
            let axis = control("editor.splitAxis", workspace, as: NSSegmentedControl.self)!
            axis.selectedSegment = 0; _ = NSApp.sendAction(axis.action!, to: axis.target, from: axis)
            workspace.window.contentView?.layoutSubtreeIfNeeded()
            check("Toolbar returns to left and right geometry", before[1].enclosingScrollView!.frame.minX > before[0].enclosingScrollView!.frame.maxX)
            if let splitter = before[0].enclosingScrollView?.superview {
                let boundary = before[0].enclosingScrollView!.frame.maxX
                let local = NSPoint(x: boundary + 0.5, y: splitter.bounds.midY)
                let start = splitter.convert(local, to: nil), end = splitter.convert(NSPoint(x: local.x + 70, y: local.y), to: nil)
                func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent { NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: workspace.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)! }
                NSApp.postEvent(mouse(.leftMouseDragged, end), atStart: false); NSApp.postEvent(mouse(.leftMouseUp, end), atStart: false)
                workspace.window.sendEvent(mouse(.leftMouseDown, start))
                check("Real divider dragging resizes panes", before[0].enclosingScrollView!.frame.width > boundary + 50)
            }
            try capture(workspace, "split-columns.png")
            check("Splitting and switching never write either original", try Data(contentsOf: a) == originalA && Data(contentsOf: b) == originalB)
            workspace.window.makeFirstResponder(right)
            let saved = workspace.desktopSnapshot
            let encoded = try JSONEncoder().encode(saved)
            let decoded = try JSONDecoder().decode(SavedWorkspace.self, from: encoded)
            let restored = app.newWindow(tabbed: false); restored.restoreDesktop(decoded)
            check("Desktop JSON restores two different files", restored.paneViewsForTesting.count == 2 && restored.paneViewsForTesting[0].string == firstDocument.storage.string && restored.paneViewsForTesting[1].string == secondDocument.storage.string)
            check("Desktop restoration keeps active pane and its selection", restored.currentDocument?.fileURL == b.standardizedFileURL.resolvingSymlinksInPath() && restored.currentTextView?.selectedRange() == NSRange(location: 7, length: 3) && restored.editorLayoutForTesting?.activePane == 1)
            check("Desktop restoration keeps the divider proportion", abs((restored.editorLayoutForTesting?.fraction ?? 0) - (saved.editorLayout?.fraction ?? 1)) < 0.001)
            check("Desktop restoration keeps both independent scroll positions", abs(restored.paneViewsForTesting[0].enclosingScrollView!.contentView.bounds.origin.y - originalView.enclosingScrollView!.contentView.bounds.origin.y) < 2 && restored.paneViewsForTesting[1].enclosingScrollView!.contentView.bounds.origin.y == 0)
            restored.window.performClose(nil)
            secondDocument.setTextUndoably("Unfinished draft 中文😀", actionName: "Draft fixture")
            right.setSelectedRange(NSRange(location: 2, length: 3))
            let sessionURL = directory.appendingPathComponent("split-session.json")
            try workspace.sessionSnapshot.save(sessionURL)
            let loaded = try EditorSession.load(sessionURL)
            let recovered = app.newWindow(tabbed: false)
            check("Session restores independently edited panes", recovered.restoreSession(loaded) && recovered.paneViewsForTesting.count == 2 && recovered.paneViewsForTesting[1].string == "Unfinished draft 中文😀" && recovered.paneViewsForTesting[0].string == source)
            check("Session restores the active cursor without saving the source", recovered.currentTextView?.selectedRange() == NSRange(location: 2, length: 3) && recovered.currentDocument?.isModified == true && (try? Data(contentsOf: b)) == originalB)
            for document in recovered.documents { document.checkpoint() }; recovered.window.performClose(nil)
            let recoveryDirectory = directory.appendingPathComponent("recovery")
            workspace.setAutoRecovery(true, directory: recoveryDirectory)
            workspace.updateRecoveryForTesting()
            if let backupURL = workspace.recoveryURLForTesting {
                for _ in 0..<30 { if FileManager.default.fileExists(atPath: backupURL.path) { break }; await pump() }
                let draft = try EditorSession.load(backupURL)
                check("Draft-only snapshot includes one modified file and two pane identities", draft.documents.count == 1 && draft.editorLayout?.panes.count == 2)
                let draftWindow = app.newWindow(tabbed: false)
                if let desktop = draft.workspace { draftWindow.restoreDesktop(desktop) }
                check("Draft-only recovery keeps the clean companion and edited file", draftWindow.restoreSession(draft, preservingCleanDocuments: true) && draftWindow.paneViewsForTesting[0].string == source && draftWindow.paneViewsForTesting[1].string == "Unfinished draft 中文😀")
                for document in draftWindow.documents { document.checkpoint() }; draftWindow.window.performClose(nil)
            } else { check("Draft-only backup has a recovery identity", false) }
            workspace.setAutoRecovery(false)
            secondDocument.undoManager.undo()
            let retainedRight = workspace.currentTextView
            let join = control("editor.joinPanes", workspace, as: NSButton.self)!
            join.performClick(nil)
            check("Single Pane keeps the active editor and both open files", workspace.paneViewsForTesting.count == 1 && workspace.currentTextView === retainedRight && workspace.documents.count == 2 && workspace.currentDocument === secondDocument)
            check("Joining releases inactive layout managers", firstDocument.storage.layoutManagers.isEmpty && secondDocument.storage.layoutManagers.count == 1)
            check("Split commands from the palette dispatcher remain available", workspace.executeCommand("split_down") && workspace.editorLayoutForTesting?.axis == .rows)
            check("Open in Other Pane chooses another existing file", menu("Open in Other Pane", workspace) && workspace.currentDocument === firstDocument)
            workspace.window.setContentSize(NSSize(width: 760, height: 420)); workspace.window.contentView?.layoutSubtreeIfNeeded()
            let toolbar = control("editor.splitToolbar", workspace, as: EditorSplitToolbar.self)!
            check("Narrow split controls fit without horizontal clipping", toolbar.subviews.allSatisfy { $0.frame.minX >= 0 && $0.frame.maxX <= toolbar.bounds.width } && toolbar.bounds.height == 66)
            workspace.window.setFrame(normalFrame, display: true)
            var light = EditorConfiguration(); light.theme = "light"; workspace.applyConfiguration(light); await pump()
            check("Split editor adopts the light theme", workspace.snapshot["theme"] as? String == "light" && workspace.paneViewsForTesting.allSatisfy { $0.backgroundColor == EditorTheme.background })
            try capture(workspace, "split-light.png")
            var legacy = saved; legacy.editorLayout = nil
            let old = app.newWindow(tabbed: false); old.restoreDesktop(legacy)
            check("Legacy split state still opens two views of the selected file", old.paneViewsForTesting.count == 2 && old.paneViewsForTesting[0].textStorage === old.paneViewsForTesting[1].textStorage)
            old.window.performClose(nil)
            let thirdURL = directory.appendingPathComponent("third.md")
            try "# Third\n".write(to: thirdURL, atomically: true, encoding: .utf8)
            workspace.openDocument(thirdURL)
            let thirdDocument = workspace.currentDocument!
            let thirdView = workspace.currentTextView!
            let inactiveTab = descendants(workspace.window.contentView!).compactMap { $0 as? NSButton }.first { $0.title == firstDocument.displayName }!
            let rightClick = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: workspace.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            let tabMenu = inactiveTab.menu(for: rightClick)
            let splitItem = tabMenu?.item(withTitle: "Split Right")
            check("Inactive file-tab context menu has split actions", splitItem != nil && tabMenu?.item(withTitle: "Split Down") != nil)
            if let item = splitItem, let action = item.action { _ = NSApp.sendAction(action, to: item.target, from: item) }
            check("Inactive-tab splitting opens that file beside the active one", workspace.paneViewsForTesting[0].textStorage === firstDocument.storage && workspace.paneViewsForTesting[1].textStorage === thirdDocument.storage && workspace.paneViewsForTesting[1] === thirdView)
            // Other restoration fixtures created and closed key windows above.
            // Establish the target window before testing real mouse/Save routing.
            NSApp.activate(ignoringOtherApps: true)
            workspace.window.makeKeyAndOrderFront(nil)
            let focusDeadline = Date().addingTimeInterval(2)
            while !(NSApp.isActive && NSApp.keyWindow === workspace.window), Date() < focusDeadline { await pump() }
            let ownsFocus = NSApp.isActive && NSApp.keyWindow === workspace.window
            check("Mouse routing fixture owns the active window", ownsFocus)
            guard ownsFocus else {
                print(String(decoding: try! JSONSerialization.data(withJSONObject: ["passed": passed, "failed": failures.count, "failures": failures], options: [.sortedKeys]), as: UTF8.self))
                return 1
            }
            let point = thirdView.convert(NSPoint(x: 24, y: 18), to: nil)
            func click(_ type: NSEvent.EventType) -> NSEvent { NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: workspace.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)! }
            NSApp.postEvent(click(.leftMouseUp), atStart: false); workspace.window.sendEvent(click(.leftMouseDown)); await pump()
            check("Actual mouse focus selects the pane's document", workspace.currentDocument === thirdDocument && workspace.currentTextView === thirdView)
            thirdDocument.setTextUndoably("# Saved third file\n", actionName: "Save routing fixture")
            workspace.activateMenus()
            let save = NSApp.mainMenu?.item(withTitle: "File")?.submenu?.item(withTitle: "Save")
            if let save, let action = save.action { _ = NSApp.sendAction(action, to: save.target, from: save) }
            check("Native Save targets the focused file and leaves other originals", (try? String(contentsOf: thirdURL)) == "# Saved third file\n" && (try? Data(contentsOf: a)) == originalA && (try? Data(contentsOf: b)) == originalB)
            _ = workspace.executeCommand("close_tab")
            workspace.selectDocument(0)
            var malformed = loaded
            malformed.editorLayout?.panes[0].scrollY = -1
            try JSONEncoder().encode(malformed).write(to: sessionURL)
            do { _ = try EditorSession.load(sessionURL); check("Malformed split metadata rejected at session loading", false) } catch { check("Malformed split metadata rejected at session loading", true) }
            _ = workspace.executeCommand("close_tab")
            check("Closing an active file leaves valid panes over retained files", workspace.documents.count == 1 && workspace.paneViewsForTesting.allSatisfy { $0.textStorage === workspace.documents[0].storage })
            _ = workspace.executeCommand("close_tab")
            check("Closing the final file returns home and disables splitting", workspace.documents.isEmpty && workspace.paneViewsForTesting.isEmpty && control("workspace.splitEditor", workspace, as: NSButton.self)?.isEnabled == false)
            workspace.window.performClose(nil)
            let lifetime = app.newWindow(openURLs: [a], tabbed: false)
            weak var releasedDocument = lifetime.currentDocument
            _ = lifetime.executeCommand("split_right")
            _ = lifetime.executeCommand("close_tab"); await pump()
            check("Closing the final split file releases the document while home remains open", releasedDocument == nil && lifetime.documents.isEmpty)
            lifetime.window.performClose(nil)
        } catch { failures.append(error.localizedDescription) }
        let result: [String: Any] = ["passed": passed, "failed": failures.count, "failures": failures]
        let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        try? data.write(to: directory.appendingPathComponent("results.json"))
        print(String(decoding: data, as: UTF8.self))
        return failures.isEmpty ? 0 : 1
    }

    @MainActor static func restart(directory: URL, write: Bool) async -> Int32 {
        var passed = 0, failures: [String] = []
        func check(_ name: String, _ value: Bool) { if value { passed += 1 } else { failures.append(name) } }
        do {
            let app = EditorAppDelegate(recentFiles: RecentLocations(defaults: nil), desktopStore: EditorDesktopStore(directory: directory.appendingPathComponent("support")))
            let sessionURL = directory.appendingPathComponent("session.json"), desktopURL = directory.appendingPathComponent("desktop.json")
            let a = directory.appendingPathComponent("first.swift"), b = directory.appendingPathComponent("second.txt")
            if write {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let text = (0..<300).map { "let value\($0) = \"" + String(repeating: "long text ", count: 30) + "\"\n" }.joined()
                try text.write(to: a, atomically: true, encoding: .utf8)
                try "Original second file\n".write(to: b, atomically: true, encoding: .utf8)
                let workspace = app.newWindow(openURLs: [a, b], tabbed: false)
                workspace.window.setContentSize(NSSize(width: 1220, height: 810))
                workspace.selectDocument(0); _ = workspace.executeCommand("split_down")
                _ = workspace.executeCommand("focus_next_pane"); workspace.selectDocument(1)
                workspace.currentDocument?.setTextUndoably("Unfinished draft 中文😀", actionName: "Restart fixture")
                workspace.currentTextView?.setSelectedRange(NSRange(location: 6, length: 3))
                var config = EditorConfiguration(); config.wordWrap = false; workspace.applyConfiguration(config)
                workspace.paneViewsForTesting[0].setSelectedRange(NSRange(location: 4, length: 2))
                workspace.window.contentView?.layoutSubtreeIfNeeded()
                workspace.paneViewsForTesting[0].scroll(NSPoint(x: 90, y: 500))
                try? await Task.sleep(nanoseconds: 200_000_000)
                try workspace.sessionSnapshot.save(sessionURL)
                let desktop = workspace.desktopSnapshot
                try JSONEncoder().encode(desktop).write(to: desktopURL)
                check("Writer captures two panes and the modified buffer", workspace.sessionSnapshot.editorLayout?.panes.count == 2 && workspace.currentDocument?.isModified == true)
                check("Writer captures independent horizontal and vertical scrolling", (desktop.editorLayout?.panes[0].scrollX ?? 0) > 50 && (desktop.editorLayout?.panes[0].scrollY ?? 0) > 400)
                check("Writer never changes original second file", (try? String(contentsOf: b)) == "Original second file\n")
                for document in workspace.documents { document.checkpoint() }; workspace.window.performClose(nil)
            } else {
                let desktop = try JSONDecoder().decode(SavedWorkspace.self, from: Data(contentsOf: desktopURL))
                let session = try EditorSession.load(sessionURL)
                let workspace = app.newWindow(tabbed: false)
                var config = EditorConfiguration(); config.wordWrap = false; workspace.applyConfiguration(config)
                workspace.restoreDesktop(desktop)
                check("New process restores the desktop pane files", workspace.paneViewsForTesting.count == 2 && workspace.paneViewsForTesting[0].string.hasPrefix("let value0") && workspace.paneViewsForTesting[1].string == "Original second file\n")
                check("Desktop restores both scroll axes after window sizing", (workspace.editorLayoutForTesting?.panes[0].scrollX ?? 0) > 50 && (workspace.editorLayoutForTesting?.panes[0].scrollY ?? 0) > 400)
                check("New process restores the unsaved session", workspace.restoreSession(session, preservingCleanDocuments: true))
                check("Restart retains rows and the active bottom pane", workspace.editorLayoutForTesting?.axis == .rows && workspace.editorLayoutForTesting?.activePane == 1 && workspace.currentDocument?.fileURL == b.standardizedFileURL.resolvingSymlinksInPath())
                if failures.contains("Restart retains rows and the active bottom pane") {
                    fputs("Restart detail: axis=\(String(describing: workspace.editorLayoutForTesting?.axis)), active=\(String(describing: workspace.editorLayoutForTesting?.activePane)), path=\(workspace.currentDocument?.fileURL?.path ?? "nil"), expected=\(b.path)\n", stderr)
                }
                check("Restart preserves clean companion and dirty buffer", workspace.paneViewsForTesting[0].string.hasPrefix("let value0") && workspace.paneViewsForTesting[1].string == "Unfinished draft 中文😀" && workspace.currentDocument?.isModified == true)
                check("Restart retains independent selections", workspace.paneViewsForTesting[0].selectedRange() == NSRange(location: 4, length: 2) && workspace.paneViewsForTesting[1].selectedRange() == NSRange(location: 6, length: 3))
                check("Restart retains both scroll axes", (workspace.editorLayoutForTesting?.panes[0].scrollX ?? 0) > 50 && (workspace.editorLayoutForTesting?.panes[0].scrollY ?? 0) > 400)
                check("Restart leaves the original file unchanged", (try? String(contentsOf: b)) == "Original second file\n")
                for document in workspace.documents { document.checkpoint() }; workspace.window.performClose(nil)
            }
        } catch { failures.append(error.localizedDescription) }
        print(String(decoding: try! JSONSerialization.data(withJSONObject: ["passed": passed, "failed": failures.count, "failures": failures], options: [.sortedKeys]), as: UTF8.self))
        return failures.isEmpty ? 0 : 1
    }
}
