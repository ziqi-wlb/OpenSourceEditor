import AppKit

enum LifecycleUITests {
    @MainActor static func run(delegate: EditorAppDelegate, directory: URL) async -> (passed: Int, failed: Int) {
        var passed = 0, failed = 0
        func check(_ name: String, _ value: Bool) {
            if value { passed += 1; print("PASS \(name)") }
            else { failed += 1; print("FAIL \(name)") }
        }
        func pump(_ seconds: Double = 0.1) async {
            if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: NSApp.modalWindow?.windowNumber ?? NSApp.keyWindow?.windowNumber ?? delegate.window.windowNumber,
                context: nil, subtype: 0, data1: 0, data2: 0) { NSApp.postEvent(event, atStart: false) }
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        func key(_ text: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: NSApp.modalWindow?.windowNumber ?? NSApp.keyWindow?.windowNumber ?? delegate.window.windowNumber,
                    context: nil, characters: text, charactersIgnoringModifiers: text.lowercased(), isARepeat: false, keyCode: code) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
        }
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        func waitSheet(excluding previous: NSWindow? = nil) async -> NSWindow? {
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if let sheet = delegate.window.attachedSheet, sheet !== previous, sheet.isVisible { return sheet }
                await pump(0.03)
            }
            return nil
        }
        func capture(_ window: NSWindow, _ filename: String) throws {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]),
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw EditorFailure.invalidEdit("Cannot capture own child window")
            }
            try data.write(to: directory.appendingPathComponent(filename))
        }
        func awaitDismissed(_ sheet: NSWindow) async -> Bool {
            let deadline = Date().addingTimeInterval(3)
            while delegate.window.attachedSheet === sheet || NSApp.modalWindow === sheet, Date() < deadline { await pump(0.03) }
            let dismissed = delegate.window.attachedSheet !== sheet && NSApp.modalWindow !== sheet
            if !dismissed, NSApp.modalWindow === sheet { NSApp.abortModal(); await pump(0.2) }
            return dismissed
        }
        func click(_ title: String, in sheet: NSWindow) async -> Bool {
            await pump(0.15)
            guard let content = sheet.contentView,
                  let button = descendants(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == title && $0.isEnabled }) else { return false }
            let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1) { NSApp.postEvent(event, atStart: false) }
            }
            return true
        }
        func command(_ name: String) {
            // Trigger modal operations through the event loop. A modal loop inside
            // a main-dispatch callback prevents other main-queue tasks from running.
            switch name {
            case "save_all": key("s", code: 1, modifiers: [.command, .option])
            case "revert": key("r", code: 15, modifiers: [.command, .option])
            case "close_tab": key("w", code: 13, modifiers: .command)
            default: preconditionFailure("Unknown UI test command")
            }
        }
        func awaitFinished() async -> Bool {
            let deadline = Date().addingTimeInterval(3)
            while delegate.window.attachedSheet != nil || NSApp.modalWindow != nil, Date() < deadline { await pump(0.03) }
            if delegate.window.attachedSheet == nil && NSApp.modalWindow == nil { return true }
            // Stop only the modal session belonging to this test's editor.
            if let sheet = NSApp.modalWindow, sheet.sheetParent === delegate.window { NSApp.abortModal() }
            await pump(0.2)
            return false
        }
        func fileAction(_ title: String) -> Bool {
            guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == "File" })?.submenu,
                  let item = menu.items.first(where: { $0.title == title }), let action = item.action else { return false }
            return NSApp.sendAction(action, to: item.target, from: item)
        }
        let nativeChooser = delegate.fileChooser
        defer { delegate.fileChooser = nativeChooser }
        let session = delegate.sessionSnapshot
        let originalFrame = delegate.window.frame
        let diskCopies = session.documents.compactMap { item -> (URL, Data)? in
            guard let path = item.path, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
            return (URL(fileURLWithPath: path), data)
        }
        do {
            var config = EditorConfiguration()
            config.theme = delegate.snapshot["theme"] as? String ?? "dark"
            config.keyBindings["revert"] = try EditorKeyBinding.parse("cmd+option+r")
            delegate.applyConfiguration(config)
            _ = delegate.executeCommand("dismiss_palette")
            if let screen = delegate.window.screen ?? NSScreen.main {
                delegate.window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX - 150, y: screen.visibleFrame.minY - 100))
            }
            delegate.window.makeKeyAndOrderFront(nil)
            let editor = delegate.currentTextView
            delegate.window.makeFirstResponder(editor)
            _ = delegate.executeCommand("command_palette"); await pump()
            if let panel = delegate.window.childWindows?.first(where: { $0 is NSPanel && $0.isVisible }) {
                let screen = delegate.window.screen ?? NSScreen.main!
                check("palette stays inside current screen", screen.visibleFrame.contains(panel.frame))
                check("palette belongs to editor and uses normal window level", panel.parent === delegate.window && panel.level == .normal)
                if let table = panel.contentView.map(descendants)?.compactMap({ $0 as? NSTableView }).first,
                   let scroll = table.enclosingScrollView {
                    check("palette rows use full viewport width", abs(table.tableColumns[0].width - scroll.contentView.bounds.width) < 1 && table.tableColumns[0].width > 500)
                } else { check("palette rows use full viewport width", false) }
                try capture(panel, "palette.png")
                key("\u{1b}", code: 53); await pump()
                check("Escape hides and detaches child panel", !panel.isVisible && panel.parent == nil)
                check("palette dismissal restores editor focus", delegate.window.firstResponder === editor)
            } else { check("palette stays inside current screen", false) }
            delegate.window.setFrame(originalFrame, display: true)
            key("l", code: 37, modifiers: .command)
            if let sheet = await waitSheet() {
                check("input dialog attaches to editor", sheet.isSheet && sheet.sheetParent === delegate.window)
                check("input dialog inherits theme", sheet.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == delegate.window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]))
                await pump(0.2)
                try capture(sheet, "dialog.png")
                key("\u{1b}", code: 53)
                let dismissed = await awaitDismissed(sheet)
                check("input dialog Escape removes sheet and restores focus", dismissed && delegate.window.firstResponder === editor)
            } else { check("input dialog attaches to editor", false) }

            // Keep all file mutations inside the UI fixture directory.
            for document in delegate.documents { document.checkpoint() }
            let first = directory.appendingPathComponent("lifecycle-first.txt")
            let second = directory.appendingPathComponent("lifecycle-second.txt")
            try Data("first\n".utf8).write(to: first)
            try EditorEncoding.utf16LEBOM.encode("second\n").write(to: second)
            delegate.openDocument(first)
            let firstDocument = delegate.currentDocument!
            delegate.openDocument(second)
            let secondDocument = delegate.currentDocument!
            firstDocument.setTextUndoably("first edited\n", actionName: "Fixture")
            secondDocument.setTextUndoably("second edited 中文\n", actionName: "Fixture")
            let selected = delegate.currentDocument
            check("Save All menu exists and executes", fileAction("Save All"))
            check("Save All writes every dirty named document", try String(contentsOf: first, encoding: .utf8) == "first edited\n" && EditorDocument.open(second).storage.string == "second edited 中文\n" && !firstDocument.isModified && !secondDocument.isModified)
            check("Save All preserves focus and codecs", delegate.currentDocument === selected && secondDocument.encoding == .utf16LEBOM)

            let alias = directory.appendingPathComponent("lifecycle-alias.txt")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
            let count = delegate.documents.count
            delegate.openDocument(alias)
            check("alias and recent open reuse one document", delegate.documents.count == count && delegate.currentDocument === firstDocument)
            if let recent = NSApp.mainMenu?.items.first(where: { $0.title == "File" })?.submenu?.items.first(where: { $0.title == "Open Recent" })?.submenu {
                check("recent menu tracks successful canonical opens", recent.items.first?.toolTip == first.path && recent.items.filter { $0.toolTip == first.path }.count == 1)
                if let index = recent.items.firstIndex(where: { $0.toolTip == second.path }) {
                    recent.performActionForItem(at: index)
                    check("recent file action selects existing tab", delegate.currentDocument === secondDocument && delegate.documents.count == count)
                } else { check("recent file action selects existing tab", false) }
            } else { check("recent menu tracks successful canonical opens", false) }

            firstDocument.setTextUndoably("unsaved first", actionName: "Fixture")
            secondDocument.setTextUndoably("unsaved second", actionName: "Fixture")
            try Data("external change\n".utf8).write(to: first)
            command("save_all")
            if let error = await waitSheet() { _ = await click("OK", in: error) }
            let saveFailed = await awaitFinished()
            let conflictedBytes = try Data(contentsOf: first)
            let laterSavedText = try EditorDocument.open(second).storage.string
            check("Save All stops on conflict without overwriting later files", saveFailed && conflictedBytes == Data("external change\n".utf8) && laterSavedText == "second edited 中文\n" && firstDocument.isModified && secondDocument.isModified)

            delegate.openDocument(first)
            try firstDocument.setEncoding(.utf16BE)
            command("revert")
            if await waitSheet() != nil { key("\u{1b}", code: 53) }
            let revertCanceled = await awaitFinished()
            check("Revert cancel retains text, codec and undo", revertCanceled && firstDocument.storage.string == "unsaved first" && firstDocument.encoding == .utf16BE && firstDocument.undoManager.canUndo)
            command("revert")
            if await waitSheet() != nil { key("\r", code: 36) }
            let defaultCanceled = await awaitFinished()
            check("Revert Return defaults to cancel", defaultCanceled && firstDocument.storage.string == "unsaved first" && firstDocument.encoding == .utf16BE)
            command("revert")
            if let sheet = await waitSheet() { _ = await click("Revert", in: sheet) }
            let reverted = await awaitFinished()
            check("Revert reloads external bytes with disk codec", reverted && firstDocument.storage.string == "external change\n" && firstDocument.encoding == .utf8 && !firstDocument.isModified)
            check("Revert clears obsolete undo and resets caret", !firstDocument.undoManager.canUndo && delegate.currentTextView?.selectedRange() == NSRange(location: 0, length: 0))
            check("Revert clears dirty marker on visible tab", delegate.window.contentView.map(descendants)?.compactMap({ $0 as? NSButton }).contains(where: { $0.title == firstDocument.displayName }) == true)

            firstDocument.setTextUndoably("keep on decode failure", actionName: "Fixture")
            let revision = firstDocument.revision, digest = firstDocument.diskDigestHex
            try Data([0xff, 0xfe, 0xff]).write(to: first)
            command("revert")
            if let confirm = await waitSheet() {
                _ = await click("Revert", in: confirm)
                if let error = await waitSheet(excluding: confirm) { _ = await click("OK", in: error) }
            }
            let decodeFailed = await awaitFinished()
            check("failed Revert retains full document state", decodeFailed && firstDocument.storage.string == "keep on decode failure" && firstDocument.revision == revision && firstDocument.diskDigestHex == digest && firstDocument.isModified && firstDocument.undoManager.canUndo)
            try Data("external change\n".utf8).write(to: first)
            command("revert")
            if let sheet = await waitSheet() { _ = await click("Revert", in: sheet) }
            _ = await awaitFinished()
            try secondDocument.save()

            _ = delegate.executeCommand("new_file")
            let unnamed = delegate.currentDocument!
            unnamed.setTextUndoably("new file 中文\n", actionName: "Fixture")
            delegate.openDocument(second)
            secondDocument.setTextUndoably("later file change", actionName: "Fixture")
            // Move the unnamed document before a later dirty file in the owner list.
            let later = directory.appendingPathComponent("lifecycle-later.txt")
            try Data("later original\n".utf8).write(to: later)
            delegate.openDocument(later)
            let laterDocument = delegate.currentDocument!
            laterDocument.setTextUndoably("later pending\n", actionName: "Fixture")
            let beforeCancel = delegate.currentDocument
            command("save_all")
            if let sheet = await waitSheet() {
                check("untitled save uses a sheet for the correct tab", sheet is NSSavePanel && delegate.currentDocument === unnamed)
                await pump(0.2)
                try capture(sheet, "file-panel.png")
                key("\u{1b}", code: 53)
            } else { check("untitled save uses a sheet for the correct tab", false) }
            let canceled = await awaitFinished()
            let canceledBytes = try Data(contentsOf: later)
            check("canceling Save All protects remaining unsaved files", canceled && unnamed.fileURL == nil && unnamed.isModified && laterDocument.isModified && canceledBytes == Data("later original\n".utf8))
            check("canceling Save All restores selected tab", delegate.currentDocument === beforeCancel)
            // macOS remote panel controls require Accessibility permission to
            // automate. Verify accepted selections through the same owning
            // boundary, while keeping real native sheet/cancel tests above.
            let savedURL = directory.appendingPathComponent("untitled.txt")
            let chooser = SelectedFileChooser(url: savedURL)
            delegate.fileChooser = chooser
            check("Save All executes with an accepted file selection", fileAction("Save All"))
            delegate.fileChooser = nativeChooser
            check("file chooser receives intended tab name and parent", chooser.name == "untitled.txt" && chooser.parent === delegate.window)
            print("DETAIL native Save button automation unverified: remote controls require Accessibility permission")
            let completed = await awaitFinished()
            let savedLaterBytes = try Data(contentsOf: later)
            let allSaved = completed && unnamed.fileURL == directory.appendingPathComponent("untitled.txt") && !unnamed.isModified && !laterDocument.isModified && savedLaterBytes == Data("later pending\n".utf8)
            check("accepted file selection saves untitled and then remaining documents", allSaved)
            guard allSaved else { throw EditorFailure.invalidEdit("Accepted selection save did not complete; stop before modal close tests") }
            let closed = unnamed.fileURL
            if let index = delegate.documents.firstIndex(where: { $0 === unnamed }) { delegate.selectDocument(index) }
            check("Close Tab menu closes saved file", fileAction("Close Tab") && !delegate.documents.contains(where: { $0 === unnamed }))
            key("T", code: 17, modifiers: [.command, .shift]); await pump()
            check("Reopen Closed File shortcut restores file from disk", delegate.currentDocument?.fileURL == closed && delegate.currentDocument?.storage.string == "new file 中文\n")
            let reopenedDocument = delegate.currentDocument!
            reopenedDocument.setTextUndoably("discarded close edit", actionName: "Fixture")
            command("close_tab")
            if await waitSheet() != nil { key("\u{1b}", code: 53) }
            let closeCanceled = await awaitFinished()
            check("close confirmation Escape preserves modified tab", closeCanceled && delegate.currentDocument === reopenedDocument && reopenedDocument.isModified)
            command("close_tab")
            if let sheet = await waitSheet() { _ = await click("Don't Save", in: sheet) }
            let closeDiscarded = await awaitFinished()
            check("explicit Don't Save closes modified tab", closeDiscarded && !delegate.documents.contains(where: { $0 === reopenedDocument }))
            key("T", code: 17, modifiers: [.command, .shift]); await pump()
            check("reopening discarded file restores saved disk text", delegate.currentDocument?.fileURL == closed && delegate.currentDocument?.storage.string == "new file 中文\n")

            let saveOnClose = delegate.currentDocument!
            saveOnClose.setTextUndoably("saved on close\n", actionName: "Fixture")
            command("close_tab")
            if let sheet = await waitSheet() { _ = await click("Save", in: sheet) }
            let closeSaved = await awaitFinished()
            check("Save in close confirmation writes before closing", closeSaved && !delegate.documents.contains(where: { $0 === saveOnClose }) && (try? String(contentsOf: closed!, encoding: .utf8)) == "saved on close\n")
            key("T", code: 17, modifiers: [.command, .shift]); await pump()
            let activeBeforeClose = delegate.currentDocument
            firstDocument.setTextUndoably("inactive close edit", actionName: "Fixture")
            if let index = delegate.documents.firstIndex(where: { $0 === firstDocument }),
               let button = delegate.window.contentView.map(descendants)?.compactMap({ $0 as? NSButton }).first(where: { $0.title == "×" && $0.tag == index }),
               let action = button.action {
                let trigger = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard event.keyCode == 80, NSApp.modalWindow == nil else { return event }
                    _ = NSApp.sendAction(action, to: button.target, from: button)
                    return nil
                }
                key("\u{f716}", code: 80, modifiers: .function)
                if await waitSheet() != nil {
                    check("inactive tab confirmation displays intended document", delegate.currentDocument === firstDocument)
                    key("\u{1b}", code: 53)
                } else { check("inactive tab confirmation displays intended document", false) }
                let dismissed = await awaitFinished()
                if let trigger { NSEvent.removeMonitor(trigger) }
                check("canceling inactive tab close restores selected document", dismissed && delegate.currentDocument === activeBeforeClose && firstDocument.isModified)
            } else { check("inactive tab close button exists", false) }

            let suite = "source-editor-tests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let recent = RecentFiles(defaults: defaults)
            recent.note(first); recent.note(second); recent.note(alias)
            check("recent persistence keeps canonical MRU order", RecentFiles(defaults: defaults).urls == [first, second])
            recent.clear()
            check("clearing recent files persists", RecentFiles(defaults: defaults).urls.isEmpty)
        } catch { check("file lifecycle workflow", false); print("DETAIL lifecycle error \(error)") }
        _ = delegate.executeCommand("dismiss_palette")
        if let sheet = NSApp.modalWindow, sheet.sheetParent === delegate.window { NSApp.abortModal(); await pump(0.2) }
        delegate.window.setFrame(originalFrame, display: true)
        for (url, data) in diskCopies { try? data.write(to: url, options: .atomic) }
        for document in delegate.documents { document.checkpoint() }
        check("lifecycle restores original tabs after verification", delegate.restoreSession(session))
        print("Lifecycle UI tests: \(passed) passed, \(failed) failed")
        return (passed, failed)
    }
}

/// Supplies a chosen URL without pretending to press a remote native control.
private final class SelectedFileChooser: EditorFileChoosing {
    let url: URL
    var name: String?
    weak var parent: NSWindow?
    init(url: URL) { self.url = url }
    func choose(_ panel: NSSavePanel, for parent: NSWindow) -> [URL]? {
        name = panel.nameFieldStringValue
        self.parent = parent
        return [url]
    }
}
