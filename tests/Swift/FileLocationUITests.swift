import AppKit

enum FileLocationUITests {
    @MainActor static func run(directory: URL) async -> Int32 {
        var passed = 0, failures: [String] = []
        func check(_ name: String, _ value: Bool) { if value { passed += 1 } else { failures.append(name); print("FAIL: " + name) } }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func control<T: NSView>(_ id: String, _ workspace: EditorWorkspace, as type: T.Type) -> T? {
            descendants(workspace.window.contentView!).first { $0.identifier?.rawValue == id } as? T
        }
        func key(_ workspace: EditorWorkspace, _ text: String, code: UInt16) {
            workspace.window.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: workspace.window.windowNumber,
                context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!)
        }
        func enter(_ text: String, _ workspace: EditorWorkspace, submit: Bool = true) {
            _ = workspace.executeCommand("open_file_location")
            let field = control("editor.fileLocation.input", workspace, as: NSTextField.self)!
            let editor = field.currentEditor() as! NSTextView
            editor.selectAll(nil); editor.insertText(text, replacementRange: editor.selectedRange())
            if submit { key(workspace, "\r", code: 36) }
        }
        func capture(_ workspace: EditorWorkspace, _ name: String) throws {
            workspace.window.contentView?.layoutSubtreeIfNeeded()
            guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(workspace.window.windowNumber), [.boundsIgnoreFraming]) else { return }
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name))
        }
        func pump() async { try? await Task.sleep(nanoseconds: 150_000_000) }
        func waitForPresentation(_ workspace: EditorWorkspace) async {
            for _ in 0..<40 {
                if workspace.snapshot["fullScreenTransition"] as? Bool == false { return }
                await pump()
            }
        }
        func menuAction(_ title: String, _ workspace: EditorWorkspace) -> Bool {
            workspace.activateMenus()
            func find(_ menu: NSMenu) -> NSMenuItem? {
                for item in menu.items {
                    if item.title == title { return item }
                    if let submenu = item.submenu, let found = find(submenu) { return found }
                }
                return nil
            }
            guard let item = find(NSApp.mainMenu!), let action = item.action, workspace.validateMenuItem(item) else { return false }
            return NSApp.sendAction(action, to: item.target, from: item)
        }
        do {
            let root = directory.appendingPathComponent("Project 中文😀")
            let nested = root.appendingPathComponent("src")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let a = root.appendingPathComponent("README.md"), b = nested.appendingPathComponent("README.md")
            let c = nested.appendingPathComponent("notes 中文 full.txt"), d = root.appendingPathComponent("other.swift")
            for (url, text) in [(a, "# First\n"), (b, "# Nested\n"), (c, "Notes 中文😀\n"), (d, "let value = 1\n")] {
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            let original = try Data(contentsOf: a)
            let app = EditorAppDelegate(recentFiles: RecentLocations(defaults: nil), desktopStore: EditorDesktopStore(directory: directory.appendingPathComponent("support")), recentFolders: RecentLocations(defaults: nil, kind: .folders))
            let workspace = app.newWindow(tabbed: false)
            workspace.window.setContentSize(NSSize(width: 1220, height: 810))
            let location = control("editor.fileLocation", workspace, as: FileLocationBar.self)!
            let field = location.field
            check("Home exposes an empty editable location without creating a file", !location.isHidden && field.stringValue.isEmpty && workspace.documents.isEmpty)
            workspace.activateMenus()
            let menu = NSApp.mainMenu!.item(withTitle: "File")!.submenu!.item(withTitle: "Open File by Name or Path…")!
            check("File menu exposes the location action and shortcut", workspace.validateMenuItem(menu) && menu.keyEquivalent == "o" && menu.keyEquivalentModifierMask == [.command, .option])
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: workspace.window.windowNumber, context: nil, characters: "o", charactersIgnoringModifiers: "o", isARepeat: false, keyCode: 31) {
                check("Native shortcut focuses the file input", NSApp.mainMenu?.performKeyEquivalent(with: event) == true && field.currentEditor() != nil)
            }
            enter(a.path, workspace)
            check("Native Return opens an absolute path from home", workspace.currentDocument?.fileURL == a && workspace.documents.count == 1 && workspace.window.firstResponder === workspace.currentTextView)
            check("Location displays the active full path", field.stringValue == a.path)
            let first = workspace.currentDocument!
            first.setTextUndoably("# Unsaved original\n", actionName: "Location fixture")
            enter(a.absoluteString, workspace)
            check("File URL reuses an existing dirty document", workspace.currentDocument === first && workspace.documents.count == 1 && first.storage.string == "# Unsaved original\n" && first.isModified)
            enter("src/notes 中文 full.txt", workspace)
            check("Without a project relative paths use the current file folder", workspace.currentDocument?.fileURL == c)
            workspace.setProject(root); await pump()
            enter("other.swift", workspace)
            check("Exact complete filename opens a project-root file", workspace.currentDocument?.fileURL == d)
            enter("notes 中文 full.txt", workspace)
            check("Project index resolves a nested Unicode filename", workspace.currentDocument?.fileURL == c)
            check("Sidebar follows a file opened through the location", workspace.desktopSnapshot.sidebar?.selectedPath == "src/notes 中文 full.txt")
            enter("../README.md", workspace)
            check("Project-relative paths do not use the active file folder", workspace.currentDocument?.fileURL == c && field.stringValue == "../README.md")
            key(workspace, "\u{1b}", code: 53)
            check("Escape restores the active path and editor focus", field.stringValue == c.path && workspace.window.firstResponder === workspace.currentTextView)
            check("Cancelling an invalid path dismisses its notification", workspace.snapshot["notice"] as? String == "")
            enter("src/../README.md", workspace)
            check("Relative path normalization reuses the original tab", workspace.currentDocument === first && first.isModified)
            enter("README.md", workspace)
            check("Duplicate complete filenames require a choice", workspace.snapshot["paletteVisible"] as? Bool == true && workspace.currentDocument === first)
            let panel = NSApp.windows.first { $0.isVisible && $0 !== workspace.window && $0.contentView.map { descendants($0).contains { $0 is NSTableView } } == true }!
            let table = descendants(panel.contentView!).compactMap { $0 as? NSTableView }.first!
            check("Duplicate chooser shows both matching files", table.numberOfRows == 2)
            table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            _ = NSApp.sendAction(table.doubleAction!, to: table.target, from: table)
            check("Choosing the nested match opens the chosen path", workspace.currentDocument?.fileURL == b && workspace.snapshot["paletteVisible"] as? Bool == false)
            enter(c.path, workspace, submit: false)
            let open = control("editor.fileLocation.open", workspace, as: NSButton.self)!
            workspace.window.makeFirstResponder(open)
            open.performClick(nil)
            check("Open button retains entered text across ending field editing", workspace.currentDocument?.fileURL == c && field.stringValue == c.path)
            let count = workspace.documents.count
            for invalid in [root.path, root.appendingPathComponent("missing.txt").path, "https://example.com/readme.md", "file:///tmp/example?query=1"] {
                enter(invalid, workspace)
                check("Invalid input leaves files unchanged: " + invalid, workspace.currentDocument?.fileURL == c && workspace.documents.count == count && field.stringValue == invalid && field.currentEditor() != nil)
            }
            key(workspace, "\u{1b}", code: 53)
            let homePrefix = FileManager.default.homeDirectoryForCurrentUser.path + "/"
            if d.path.hasPrefix(homePrefix) {
                enter("~/" + d.path.dropFirst(homePrefix.count), workspace)
                check("Tilde path expands to the local home directory", workspace.currentDocument?.fileURL == d)
            }
            let encoded = c.absoluteString
            enter(encoded, workspace)
            check("Percent-encoded file URL retains spaces and Unicode", workspace.currentDocument?.fileURL == c)
            check("Successful file navigation dismisses prior location errors", workspace.snapshot["notice"] as? String == "")
            enter(a.path, workspace)
            _ = workspace.executeCommand("split_right"); _ = workspace.executeCommand("focus_next_pane")
            let companion = workspace.paneViewsForTesting[0]
            enter(d.path, workspace)
            check("Location opens into the active split pane", workspace.paneViewsForTesting.count == 2 && workspace.paneViewsForTesting[0] === companion && workspace.paneViewsForTesting[1].textStorage === workspace.currentDocument?.storage && workspace.currentDocument?.fileURL == d)
            workspace.window.makeFirstResponder(companion)
            check("Focusing a different pane updates the file location", field.stringValue == a.path && workspace.currentDocument === first)
            _ = workspace.executeCommand("markdown_preview"); await pump()
            check("Markdown preview keeps the location input available", !location.isHidden && workspace.markdownPreviewForTesting != nil)
            enter(c.path, workspace)
            check("Opening from preview selects the new editor document", workspace.currentDocument?.fileURL == c && workspace.window.firstResponder === workspace.currentTextView)
            _ = menuAction("Toggle Tab Bar", workspace)
            workspace.window.contentView?.layoutSubtreeIfNeeded()
            check("Hiding file tabs retains the location input", !location.isHidden && location.frame.minY == 0)
            _ = menuAction("Toggle Tab Bar", workspace)
            await pump(); await pump()
            try capture(workspace, "file-location-dark.png")
            var config = EditorConfiguration(); config.theme = "light"; workspace.applyConfiguration(config)
            check("Location colors follow the light theme", field.textColor == EditorTheme.foreground)
            workspace.window.setContentSize(NSSize(width: 760, height: 420)); workspace.window.contentView?.layoutSubtreeIfNeeded()
            check("Narrow location keeps its input and button in bounds", field.frame.width > 150 && open.frame.maxX <= location.bounds.width && field.frame.maxX < open.frame.minX)
            await pump(); await pump()
            try capture(workspace, "file-location-light-narrow.png")
            let other = app.newWindow(openURLs: [d], tabbed: false)
            check("Windows retain independent locations", control("editor.fileLocation.input", other, as: NSTextField.self)?.stringValue == d.path && field.stringValue == c.path)
            other.window.performClose(nil)
            workspace.window.makeKeyAndOrderFront(nil)
            _ = menuAction("Toggle Focus Mode", workspace); await waitForPresentation(workspace)
            check("Focus Mode hides the location row", location.isHidden)
            enter("pending path", workspace, submit: false)
            check("Location shortcut temporarily reveals input in Focus Mode", !location.isHidden && field.currentEditor() != nil)
            key(workspace, "\u{1b}", code: 53)
            check("Escape hides the temporary row without changing the file", location.isHidden && workspace.currentDocument?.fileURL == c)
            check("Focus Mode exit is available after native fullscreen settles", menuAction("Toggle Focus Mode", workspace))
            await waitForPresentation(workspace)
            check("Exiting Focus Mode restores the location row", !location.isHidden)
            check("Navigation preserves dirty content and never saves originals", first.isModified && first.storage.string == "# Unsaved original\n" && (try? Data(contentsOf: a)) == original)
            for document in workspace.documents { document.checkpoint() }
            while !workspace.documents.isEmpty { _ = workspace.executeCommand("close_tab") }
            check("Closing all tabs restores an empty location on home", field.stringValue.isEmpty && !location.isHidden && workspace.currentDocument == nil)
            workspace.window.performClose(nil)
            let blank = app.newWindow(tabbed: false)
            enter("src/file.txt", blank)
            check("Relative path without a base leaves home unchanged", blank.documents.isEmpty && control("editor.fileLocation.input", blank, as: NSTextField.self)?.stringValue == "src/file.txt")
            key(blank, "\u{1b}", code: 53); blank.window.performClose(nil)
        } catch { failures.append(error.localizedDescription) }
        let result: [String: Any] = ["passed": passed, "failed": failures.count, "failures": failures]
        let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        try? data.write(to: directory.appendingPathComponent("results.json"))
        print(String(decoding: data, as: UTF8.self))
        return failures.isEmpty ? 0 : 1
    }
}
