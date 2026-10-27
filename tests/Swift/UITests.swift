import AppKit

enum UITestRunner {
    @MainActor static func run(delegate: EditorWorkspace, directory: URL) async -> Int32 {
        var passed = 0, failed = 0
        func check(_ name: String, _ value: Bool) {
            if value { passed += 1; print("PASS \(name)") }
            else { failed += 1; print("FAIL \(name)") }
        }
        func pump(_ seconds: Double = 0.1) async {
            if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: NSApp.modalWindow?.windowNumber ?? NSApp.keyWindow?.windowNumber ?? delegate.window.windowNumber,
                context: nil, subtype: 0, data1: 0, data2: 0) {
                NSApp.postEvent(event, atStart: false)
            }
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        func awaitIdle(_ key: String, timeout: Double = 5) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while delegate.snapshot[key] as? Bool == true, Date() < deadline { await pump(0.02) }
            return delegate.snapshot[key] as? Bool == false
        }
        func postKey(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [], ignoringModifiers: String? = nil) {
            if !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
                (NSApp.modalWindow ?? delegate.window).makeKeyAndOrderFront(nil)
            }
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: NSApp.modalWindow?.windowNumber ?? delegate.window.windowNumber,
                    context: nil, characters: characters, charactersIgnoringModifiers: ignoringModifiers ?? (modifiers.contains(.shift) ? characters.uppercased() : characters.lowercased()),
                    isARepeat: false, keyCode: keyCode) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
        }
        func activateFixture() async -> Bool {
            NSApp.activate(ignoringOtherApps: true)
            delegate.window.makeKeyAndOrderFront(nil)
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                if NSApp.isActive && NSApp.keyWindow === delegate.window { return true }
                await pump(0.02)
            }
            print("DETAIL fixture focus active=\(NSApp.isActive) key=\(NSApp.keyWindow?.windowNumber ?? -1) expected=\(delegate.window.windowNumber)")
            return false
        }
        func descendants(_ parent: NSView) -> [NSView] { parent.subviews.flatMap { [$0] + descendants($0) } }
        func submitInputDialog(_ identifier: String, keys: [(String, UInt16, NSEvent.ModifierFlags)]) async -> Bool {
            let deadline = Date().addingTimeInterval(3)
            var ownModal: NSWindow?
            while Date() < deadline {
                if let modal = NSApp.modalWindow, let content = modal.contentView,
                   let field = descendants(content).first(where: { $0.identifier?.rawValue == identifier }) as? NSTextField,
                   field.currentEditor() != nil {
                    ownModal = modal
                    for (characters, keyCode, modifiers) in keys {
                        postKey(characters, keyCode: keyCode, modifiers: modifiers)
                        await pump(0.05)
                    }
                    break
                }
                await pump(0.02)
            }
            guard let ownModal else { return false }
            while NSApp.modalWindow === ownModal, Date() < deadline { await pump(0.02) }
            if NSApp.modalWindow !== ownModal { return true }
            postKey("\u{1b}", keyCode: 53)
            await pump(0.2)
            if NSApp.modalWindow === ownModal {
                NSApp.abortModal()
                ownModal.orderOut(nil)
                await pump(0.1)
            }
            return false
        }
        func captureWindow(_ filename: String) throws {
            delegate.window.contentView?.layoutSubtreeIfNeeded()
            delegate.window.displayIfNeeded()
            guard let cgImage = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(delegate.window.windowNumber), [.boundsIgnoreFraming, .bestResolution]),
                  let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
                throw NSError(domain: "UITestWindowCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to capture editor window"])
            }
            try data.write(to: directory.appendingPathComponent(filename))
        }
        func selectStatus(_ identifier: String, path: [String], additionalKeys: [(String, UInt16, NSEvent.ModifierFlags)] = [], clickModalButton: String? = nil) async -> Bool {
            // Modal dismissal and menu tracking finish on subsequent AppKit
            // turns. Wait for this window/control before the next mouse action.
            guard await activateFixture() else { return false }
            delegate.window.contentView?.layoutSubtreeIfNeeded()
            await pump(0.05)
            guard let button = descendants(delegate.window.contentView!).first(where: { $0.identifier?.rawValue == identifier }) as? NSPopUpButton,
                  !button.isHiddenOrHasHiddenAncestor, button.visibleRect.height > 10, let initialMenu = button.menu else { return false }
            var menu = initialMenu
            let actionCount = delegate.snapshot["menuActionCount"] as? Int ?? 0
            var navigation: [(NSMenu, [NSMenuItem], Int, Bool)] = []
            var targets: [String] = []
            var expectedActionID = ""
            for (level, title) in path.enumerated() {
                let items = menu.items.filter { !$0.isSeparatorItem && !$0.isHidden && $0.isEnabled }
                guard let ordinal = items.firstIndex(where: { $0.title == title }) else { return false }
                let selected = items[ordinal]
                let target = selected.target.map { String(describing: type(of: $0)) } ?? "nil"
                targets.append("\(selected.title):action=\(selected.action.map(NSStringFromSelector) ?? "nil"),target=\(target)")
                let hasChild = level + 1 < path.count
                navigation.append((menu, items, ordinal, hasChild))
                if hasChild {
                    guard let child = selected.submenu else { return false }
                    menu = child
                } else if let action = selected.representedObject as? NSObject {
                    expectedActionID = String(describing: ObjectIdentifier(action))
                }
            }
            let location = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: delegate.window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1) { NSApp.postEvent(event, atStart: false) }
            }
            func sameMenuChoice(_ actual: NSMenuItem?, _ expected: NSMenuItem) -> Bool {
                guard let actual else { return false }
                return actual === expected || actual.title == expected.title
            }
            func waitHighlight(_ menu: NSMenu, _ expected: NSMenuItem? = nil) async -> Bool {
                let deadline = Date().addingTimeInterval(1)
                while Date() < deadline {
                    if menu.highlightedItem != nil, expected == nil || sameMenuChoice(menu.highlightedItem, expected!) { return true }
                    await pump(0.02)
                }
                print("DETAIL menu navigation expected=\(expected?.title ?? "any") highlighted=\(menu.highlightedItem?.title ?? "nil")")
                return false
            }
            func dismissMenu() async {
                initialMenu.cancelTracking()
                await pump(0.1)
            }
            for (level, step) in navigation.enumerated() {
                let (menu, items, ordinal, child) = step
                let goal = items[ordinal]
                if level > 0 {
                    guard await waitHighlight(menu) else { await dismissMenu(); return false }
                    await pump(0.05)
                } else {
                    postKey("\u{f729}", keyCode: 115, modifiers: .function)
                    guard await waitHighlight(menu, items[0]) else { await dismissMenu(); return false }
                }
                var steps = 0
                while !sameMenuChoice(menu.highlightedItem, goal), steps < menu.items.count {
                    let previousTitle = menu.highlightedItem?.title
                    guard let position = items.firstIndex(where: { sameMenuChoice(menu.highlightedItem, $0) }) else {
                        await dismissMenu(); return false
                    }
                    let moveUp = position > ordinal
                    postKey(moveUp ? "\u{f700}" : "\u{f701}", keyCode: moveUp ? 126 : 125, modifiers: .function)
                    let deadline = Date().addingTimeInterval(1)
                    while menu.highlightedItem?.title == previousTitle, Date() < deadline { await pump(0.02) }
                    let actionID = (menu.highlightedItem?.representedObject as? NSObject).map { String(describing: ObjectIdentifier($0)) } ?? "nil"
                    print("DETAIL menu step goal=\(goal.title) highlighted=\(menu.highlightedItem?.title ?? "nil") actionID=\(actionID)")
                    steps += 1
                }
                guard sameMenuChoice(menu.highlightedItem, goal) else {
                    print("DETAIL menu goal=\(goal.title) highlighted=\(menu.highlightedItem?.title ?? "nil")")
                    await dismissMenu(); return false
                }
                if child { postKey("\u{f703}", keyCode: 124, modifiers: .function) }
            }
            postKey("\r", keyCode: 36)
            let deadline = Date().addingTimeInterval(3)
            var sentAdditional = additionalKeys.isEmpty
            var ownModalWindow: NSWindow?
            while delegate.snapshot["lastMenuActionID"] as? String != expectedActionID, Date() < deadline {
                if !sentAdditional, let modal = NSApp.modalWindow,
                   let content = modal.contentView,
                   descendants(content).contains(where: { $0.identifier?.rawValue == "dialog.tabWidth" }) {
                    ownModalWindow = modal
                    print("DETAIL tab-width modal window=\(modal.windowNumber) key=\(NSApp.keyWindow?.windowNumber ?? -1) responder=\(String(describing: modal.firstResponder.map { type(of: $0) }))")
                    print("DETAIL tab-width buttons=\(descendants(content).compactMap { $0 as? NSButton }.map { ($0.title, String(reflecting: $0.keyEquivalent)) })")
                    print("DETAIL tab-width default button=\(String(reflecting: modal.defaultButtonCell?.keyEquivalent))")
                    for (characters, code, modifiers) in additionalKeys {
                        postKey(characters, keyCode: code, modifiers: modifiers)
                        await pump(0.05)
                    }
                    if let field = descendants(content).first(where: { $0.identifier?.rawValue == "dialog.tabWidth" }) as? NSTextField {
                        print("DETAIL tab-width after input value=\(field.stringValue) modal=\(NSApp.modalWindow?.windowNumber ?? -1)")
                    }
                    if let clickModalButton,
                       let button = descendants(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == clickModalButton }) {
                        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
                        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: modal.windowNumber,
                                context: nil, eventNumber: 2, clickCount: 1, pressure: 1) { NSApp.postEvent(event, atStart: false) }
                        }
                    }
                    sentAdditional = true
                }
                await pump(0.02)
            }
            let completed = delegate.snapshot["menuActionCount"] as? Int != actionCount && delegate.snapshot["lastMenuActionID"] as? String == expectedActionID
            if !completed {
                await dismissMenu()
                postKey("\u{1b}", keyCode: 53)
                await pump(0.2)
                if let ownModalWindow, NSApp.modalWindow === ownModalWindow {
                    NSApp.abortModal()
                    ownModalWindow.orderOut(nil)
                    await pump(0.1)
                }
            }
            print("DETAIL status selection \(identifier) path=\(path) targets=\(targets) selected=\(button.selectedItem?.title ?? "nil") snapshot=\(delegate.snapshot["indentation"] ?? "nil") doc=\(delegate.currentDocument?.displayName ?? "nil")")
            return completed
        }
        guard let document = delegate.currentDocument, var view = delegate.currentTextView else { print("FAIL missing real editor"); return 1 }
        let initialIndex = delegate.selectedIndex
        let otherIndex = delegate.documents.indices.first(where: { $0 != initialIndex }) ?? initialIndex
        check("Native UI fixture owns the active window", await activateFixture())
        check("visible native window", delegate.window.isVisible && delegate.window.contentView != nil)
        check("launch does not show a blank child window", delegate.window.childWindows?.isEmpty ?? true)
        check("multiple file tabs", delegate.documents.count == 2)
        do {
            let controls = descendants(delegate.window.contentView!).compactMap { $0 as? NSPopUpButton }
            check("all document status controls are visible", ["status.encoding", "status.lineEnding", "status.indentation", "status.syntax"].allSatisfy { id in
                controls.contains { $0.identifier?.rawValue == id && !$0.isHiddenOrHasHiddenAncestor && $0.visibleRect.height > 10 }
            })
            document.setTextUndoably("\t中文😀", actionName: "Status Fixture")
            view.setSelectedRange(NSRange(location: 5, length: 0)); await pump()
            check("visual column counts tabs and Unicode scalars", (delegate.snapshot["status"] as? String ?? "").contains("Col 8"))
            let widthClicked = await selectStatus("status.indentation", path: ["Tab Width: 2"])
            check("click status changes tab width", widthClicked && document.settings.tabSize == 2)
            let customClicked = await selectStatus("status.indentation", path: ["Other Tab Width…"],
                additionalKeys: [("a", 0, .command), ("1", 18, []), ("2", 19, [])], clickModalButton: "Set")
            check("status custom tab width accepts values above eight", customClicked && document.settings.tabSize == 12)
            let returnAccepted = await selectStatus("status.indentation", path: ["Other Tab Width…"],
                additionalKeys: [("a", 0, .command), ("9", 25, []), ("\r", 36, [])])
            check("custom tab width Return submits focused input", returnAccepted && document.settings.tabSize == 9)
            let restoredWidth = await selectStatus("status.indentation", path: ["Tab Width: 2"])
            check("status restores tab width before keyboard editing", restoredWidth && document.settings.tabSize == 2)
            let spacesClicked = await selectStatus("status.indentation", path: ["Indent Using Spaces"])
            check("click status chooses spaces", spacesClicked && document.settings.translateTabsToSpaces)
            document.setTextUndoably("a", actionName: "Tab Fixture"); await pump()
            view.setSelectedRange(NSRange(location: 1, length: 0)); delegate.window.makeFirstResponder(view)
            postKey("\t", keyCode: 48); await pump()
            check("real Tab inserts spaces to next visual stop", document.storage.string == "a ")
            postKey("\u{7f}", keyCode: 51); await pump()
            check("real Backspace removes tab-stop indentation", document.storage.string == "a")
            document.setTextUndoably("  one\n  two", actionName: "Indent Fixture"); await pump()
            view.setSelectedRange(NSRange(location: 0, length: document.storage.length))
            postKey("\u{19}", keyCode: 48, modifiers: .shift, ignoringModifiers: "\t"); await pump()
            print("DETAIL Shift Tab text=\(String(reflecting: document.storage.string)) ranges=\(view.selectedRanges)")
            check("real Shift Tab unindents selected lines", document.storage.string == "one\ntwo")
            document.setTextUndoably("  one", actionName: "Newline Fixture"); await pump()
            view.setSelectedRange(NSRange(location: document.storage.length, length: 0))
            postKey("\r", keyCode: 36); await pump()
            check("real Enter retains leading indentation", document.storage.string == "  one\n  ")
            document.setTextUndoably("\tone\n\ttwo", actionName: "Convert Fixture"); await pump()
            let convertClicked = await selectStatus("status.indentation", path: ["Convert Indentation to Spaces"])
            check("click status converts buffer indentation", convertClicked && document.storage.string == "  one\n  two")
            let endingClicked = await selectStatus("status.lineEnding", path: ["Windows Line Endings (CRLF)"])
            await pump()
            check("click status converts line endings", endingClicked && document.storage.string == "  one\r\n  two" && document.settings.lineEnding == .crlf)
            check("CRLF ruler draws each logical line once", (delegate.snapshot["rulerLineNumbers"] as? [[Int]])?.first == [1, 2])
            if let utf16 = EditorEncoding.allCases.first(where: { !$0.hasBOM && $0.displayName.contains("UTF-16") && $0.displayName.contains("LE") }) {
                let encodedClicked = await selectStatus("status.encoding", path: ["Set Encoding", utf16.displayName])
                check("click encoding changes pending save codec", encodedClicked && document.encoding == utf16)
                let saved = directory.appendingPathComponent("status-encoding.txt")
                try document.save(to: saved, allowOverwrite: true)
                let reopened = try EditorDocument.open(saved, encoding: utf16)
                check("status encoding and line ending affect saved bytes", reopened.storage.string == "  one\r\n  two" && reopened.encoding == utf16)
                let reopenClicked = await selectStatus("status.encoding", path: ["Reopen with Encoding", utf16.displayName])
                check("click encoding can reopen from disk", reopenClicked && !document.isModified && document.storage.string == reopened.storage.string)
            } else { check("UTF-16 status encoding available", false) }
            if let swift = EditorSyntax.allCases.first(where: { $0.displayName == "Swift" }) {
                let syntaxClicked = await selectStatus("status.syntax", path: [swift.displayName])
                check("click status overrides syntax", syntaxClicked && document.syntaxIdentifier == swift.rawValue)
            } else { check("Swift syntax status available", false) }
            let tab0 = document.settings
            delegate.selectDocument(otherIndex); await pump()
            delegate.selectDocument(initialIndex); await pump(); view = delegate.currentTextView!
            check("status settings survive tab focus changes", document.settings == tab0 && delegate.snapshot["indentation"] as? String == "Spaces: 2")
            let snapshot = delegate.sessionSnapshot
            check("session records document settings", snapshot.documents[initialIndex].settings == document.settings)
            document.setTextUndoably("one\r\ntwo\r\nthree", actionName: "Go to Line Fixture")
            view.setSelectedRange(NSRange(location: 0, length: 0)); delegate.window.makeFirstResponder(view)
            postKey("l", keyCode: 37, modifiers: .command)
            let lineAccepted = await submitInputDialog("dialog.goToLine", keys: [("3", 20, []), ("\r", 36, [])])
            await pump()
            check("Go to Line Return submits input and counts CRLF once", lineAccepted && view.selectedRange() == NSRange(location: 10, length: 0))
            var reset = document.settings
            reset.tabSize = 4; reset.translateTabsToSpaces = false; reset.lineEnding = .lf; reset.syntax = nil
            try document.updateSettings(reset)
            document.convertLineEndings(to: .lf, selections: [NSRange(location: 0, length: 0)])
            try document.setEncoding(.utf8)
            document.checkpoint()
        } catch { check("status control workflow", false); print(error) }
        if let preferences = NSApp.mainMenu?.items.first(where: { $0.title == "Preferences" })?.submenu {
            func themeMenu() -> NSMenu? { NSApp.mainMenu?.items.first(where: { $0.title == "Preferences" })?.submenu?.items.first(where: { $0.title == "Theme" })?.submenu }
            if let menu = themeMenu(), let index = menu.items.firstIndex(where: { $0.title == "Light" }) {
                let savedIndentation = document.settings
                menu.performActionForItem(at: index); await pump()
                check("Theme menu changes to light immediately", delegate.snapshot["theme"] as? String == "light" && view.backgroundColor == NSColor(calibratedWhite: 0.98, alpha: 1))
                check("theme preserves document indentation settings", document.settings == savedIndentation)
                do { try captureWindow("theme-light.png"); check("light theme window captured", true) }
                catch { check("light theme window captured", false); print(error) }
                if let dark = themeMenu(), let index = dark.items.firstIndex(where: { $0.title == "Dark" }) {
                    dark.performActionForItem(at: index); await pump()
                    check("Theme menu restores dark immediately", delegate.snapshot["theme"] as? String == "dark" && view.backgroundColor != NSColor(calibratedWhite: 0.98, alpha: 1))
                    do { try captureWindow("theme-dark.png"); check("dark theme window captured", true) }
                    catch { check("dark theme window captured", false); print(error) }
                }
                delegate.selectDocument(otherIndex); await pump()
                check("theme survives tab focus change", delegate.currentTextView?.backgroundColor == view.backgroundColor)
                delegate.selectDocument(initialIndex); await pump(); view = delegate.currentTextView!
            }
            check("Preferences exposes supported settings actions", ["Load Settings…", "Save Settings…", "Reset Settings"].allSatisfy { title in preferences.items.contains { $0.title == title && $0.action != nil } })
        } else { check("Preferences Theme menu available", false) }
        let board = NSPasteboard.general
        let oldClipboard = (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in item.data(forType: type).map { (type, $0) } }
        }
        func restoreClipboard() {
            board.clearContents()
            let items = oldClipboard.map { contents -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in contents { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { board.writeObjects(items) }
        }
        func invokeEditMenu(_ title: String) -> Bool {
            guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == "Edit" })?.submenu,
                  let index = menu.items.firstIndex(where: { $0.title == title && $0.action != nil }) else { return false }
            menu.performActionForItem(at: index)
            return true
        }
        document.setTextUndoably("copy 中文 paste", actionName: "Clipboard Fixture"); await pump()
        _ = await activateFixture()
        view.setSelectedRange(NSRange(location: 5, length: 2)); delegate.window.makeFirstResponder(view)
        await pump(0.05)
        check("Clipboard fixture has the focused native editor", NSApp.isActive && NSApp.keyWindow === delegate.window && delegate.window.firstResponder === view && view.selectedRange() == NSRange(location: 5, length: 2))
        let copied = invokeEditMenu("Copy"); await pump()
        check("Copy menu routes to focused editor", copied && board.string(forType: .string) == "中文")
        let cut = invokeEditMenu("Cut"); await pump()
        check("Cut menu edits focused document", cut && document.storage.string == "copy  paste")
        let undone = invokeEditMenu("Undo"); await pump()
        check("Undo menu restores cut text", undone && document.storage.string == "copy 中文 paste")
        view.setSelectedRange(NSRange(location: document.storage.length, length: 0))
        let pasted = invokeEditMenu("Paste"); await pump()
        check("Paste menu inserts at focused caret", pasted && document.storage.string == "copy 中文 paste中文")
        restoreClipboard()
        delegate.openProject(EditorProject(folderURL: directory)); await pump(0.2)
        check("project tree inventory", (delegate.snapshot["projectFiles"] as? Int ?? 0) >= 2)
        if let tree = descendants(delegate.window.contentView!).compactMap({ $0 as? NSOutlineView }).first,
           let scroll = tree.enclosingScrollView {
            func checkTreeWidth(_ name: String) {
                print("DETAIL \(name) tree=\(tree.frame) column=\(tree.tableColumns[0].width) viewport=\(scroll.contentView.bounds)")
                check(name, abs(tree.frame.width - scroll.contentView.bounds.width) < 2 && abs(tree.tableColumns[0].width - scroll.contentView.bounds.width) < 2)
            }
            checkTreeWidth("folder opened after startup fills sidebar")
            do {
                let fixture = directory.appendingPathComponent("tree-fixture")
                let nested = fixture.appendingPathComponent("nested-folder")
                try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
                try "nested\n".write(to: nested.appendingPathComponent("nested-中文.swift"), atomically: true, encoding: .utf8)
                for index in 0..<60 {
                    try "file\n".write(to: fixture.appendingPathComponent(String(format: "file-%02d.txt", index)), atomically: true, encoding: .utf8)
                }
                delegate.openProject(EditorProject(folderURL: fixture)); await pump(0.2)
                checkTreeWidth("switching folders preserves sidebar width")
                check("folder tree contains every visible direct child", tree.numberOfRows == 62)
                tree.expandItem(tree.item(atRow: 1)); await pump()
                check("expanded subfolder shows nested file", tree.numberOfRows == 63 && tree.view(atColumn: 0, row: 2, makeIfNecessary: true)?.toolTip?.hasSuffix("nested-中文.swift") == true)
                let firstFile = tree.view(atColumn: 0, row: 3, makeIfNecessary: true)
                let labels = firstFile.map(descendants)?.compactMap { $0 as? NSTextField } ?? []
                check("sidebar file names have usable label width", labels.contains { $0.stringValue == "file-00.txt" && $0.frame.width > 70 })
                let originalFrame = delegate.window.frame
                delegate.window.setContentSize(NSSize(width: 900, height: 620)); await pump()
                checkTreeWidth("window resize preserves sidebar width")
                tree.scrollRowToVisible(tree.numberOfRows - 1); await pump()
                check("sidebar scroll reaches final file", tree.visibleRect.intersection(tree.rect(ofRow: tree.numberOfRows - 1)).height > 10)
                delegate.window.setFrame(originalFrame, display: true); await pump()
                delegate.openProject(EditorProject(folderURL: directory)); await pump(0.2)
            } catch { check("folder sidebar workflow", false); print(error) }
        } else { check("folder sidebar exists", false) }
        let original = document.storage.string
        view.selectedRanges = [NSValue(range: NSRange(location: 0, length: 0))]
        view.insertText("中文😀", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.breakUndoCoalescing(); await pump()
        check("AppKit Unicode insert", document.storage.string.hasPrefix("中文😀"))
        document.undoManager.undo(); await pump()
        check("AppKit insert undo", document.storage.string == original)
        document.undoManager.redo(); await pump()
        check("AppKit insert redo", document.storage.string.hasPrefix("中文😀"))
        document.setTextUndoably("😀 a 😀 b", actionName: "Fixture")
        await pump(); document.undoManager.removeAllActions()
        view.selectedRanges = [NSValue(range: NSRange(location: 0, length: 2)), NSValue(range: NSRange(location: 5, length: 2))]
        view.insertText("中", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.breakUndoCoalescing(); await pump()
        print("DETAIL multi insert text=\(document.storage.string.debugDescription) ranges=\(view.selectedRanges)")
        check("AppKit multi-selection replace", document.storage.string == "中 a 中 b" && view.selectedRanges.count == 2)
        document.undoManager.undo(); await pump()
        print("DETAIL multi undo text=\(document.storage.string.debugDescription) ranges=\(view.selectedRanges)")
        check("multi-selection single undo", document.storage.string == "😀 a 😀 b")
        check("undo restores valid multiple selections", view.selectedRanges.map(\.rangeValue) == [NSRange(location: 0, length: 2), NSRange(location: 5, length: 2)])
        document.undoManager.redo(); await pump()
        check("multi-selection redo", document.storage.string == "中 a 中 b")
        delegate.window.makeFirstResponder(view)
        postKey("X", keyCode: 7, modifiers: .shift); await pump()
        check("continued typing at multiple carets", document.storage.string == "中X a 中X b" && view.selectedRanges.count == 2)
        print("DETAIL after typing undo=\(document.undoManager.undoActionName) group=\(document.undoManager.groupingLevel)")
        postKey("\u{7f}", keyCode: 51); await pump()
        check("multiple caret delete", document.storage.string == "中 a 中 b" && view.selectedRanges.count == 2)
        print("DETAIL after deletion undo=\(document.undoManager.undoActionName) group=\(document.undoManager.groupingLevel)")
        document.undoManager.undo(); await pump()
        print("DETAIL delete undo text=\(document.storage.string.debugDescription) ranges=\(view.selectedRanges)")
        check("multiple caret delete undo", document.storage.string == "中X a 中X b")
        _ = delegate.executeCommand("split"); await pump()
        view = delegate.currentTextView!
        check("split panes", delegate.snapshot["paneCount"] as? Int == 2)
        func textViews(_ container: NSView) -> [NSTextView] {
            (container as? NSTextView).map { [$0] } ?? container.subviews.flatMap(textViews)
        }
        let shared = textViews(delegate.window.contentView!).filter { $0.textStorage === document.storage }
        check("split uses shared live storage", shared.count == 2)
        document.setTextUndoably("cat cat cat\n", actionName: "Fixture"); await pump()
        view.setSelectedRange(NSRange(location: 0, length: 3))
        _ = delegate.executeCommand("select_next")
        print("DETAIL select next ranges=\(view.selectedRanges), current=\(delegate.currentTextView?.selectedRanges ?? [])")
        check("select next occurrence", view.selectedRanges.count == 2)
        _ = delegate.executeCommand("select_all_occurrences")
        check("select all occurrences", view.selectedRanges.count == 3)
        document.setTextUndoably("b\na\n", actionName: "Fixture"); view.setSelectedRange(NSRange(location: 0, length: 0)); await pump()
        _ = delegate.executeCommand("sort_lines"); await pump()
        check("sort menu command", document.storage.string == "a\nb\n")
        do {
            try document.save(); await pump()
            let saved = try String(contentsOf: document.fileURL!, encoding: .utf8)
            check("save real file", saved == "a\nb\n" && !document.isModified)
            let config = try JSONDecoder().decode(EditorConfiguration.self, from: Data("{\"theme\":\"light\",\"fontSize\":16,\"tabSize\":2,\"keyBindings\":{\"build\":\"cmd+shift+b\"}}".utf8))
            delegate.applyConfiguration(config)
            print("DETAIL config theme=\(delegate.snapshot["theme"] ?? "nil") font=\(String(describing: view.font))")
            check("live configuration", delegate.snapshot["theme"] as? String == "light" && view.font?.pointSize == 16)
            check("Configuration styles all split storage", shared.allSatisfy { $0.font?.pointSize == 16 } &&
                  (document.storage.attribute(.font, at: document.storage.length - 1, effectiveRange: nil) as? NSFont)?.pointSize == 16)
            let beforeReselect = delegate.currentTextView
            let beforeReselectRanges = beforeReselect?.selectedRanges
            delegate.selectDocument(delegate.documents.firstIndex(where: { $0 === document })!)
            check("Reselecting active tab preserves view and selections", delegate.currentTextView === beforeReselect &&
                  delegate.currentTextView?.selectedRanges == beforeReselectRanges)
            let styledSource = document.storage.string
            let styledRevision = document.revision
            delegate.applyConfiguration(config)
            check("Presentation preserves clean text and revision", document.storage.string == styledSource &&
                  document.revision == styledRevision && !document.isModified)
            var noWrap = config
            noWrap.wordWrap = false
            delegate.applyConfiguration(noWrap)
            document.setTextUndoably(String(repeating: "wide text ", count: 100), actionName: "No Wrap")
            await pump(0.2)
            check("no-wrap supports horizontal content", view.frame.width > (view.enclosingScrollView?.contentView.bounds.width ?? view.frame.width) * 1.5)
            delegate.applyConfiguration(config)
        } catch { check("save/configuration", false); print(error) }
        _ = delegate.executeCommand("find"); await pump()
        check("find activates search field", delegate.window.firstResponder is NSTextView && delegate.window.firstResponder !== view)
        if let findMenu = NSApp.mainMenu?.items.first(where: { $0.title == "Find" })?.submenu,
           let replaceMenu = findMenu.items.first(where: { $0.action == NSSelectorFromString("showReplace") }),
           let action = replaceMenu.action {
            NSApp.sendAction(action, to: replaceMenu.target, from: replaceMenu)
            await pump()
        }
        let controls = descendants(delegate.window.contentView!)
        if let search = controls.compactMap({ $0 as? NSSearchField }).first,
           let replacement = controls.compactMap({ $0 as? NSTextField }).first(where: { $0.placeholderString == "Replace with" }),
           let replaceAll = controls.compactMap({ $0 as? NSButton }).first(where: { $0.title == "All" }),
           let replaceOne = controls.compactMap({ $0 as? NSButton }).first(where: { $0.title == "Replace" }),
           let regex = controls.compactMap({ $0 as? NSButton }).first(where: { $0.toolTip == "Use regular expressions" }) {
            check("replace menu shows usable controls", !replacement.isHiddenOrHasHiddenAncestor && replacement.visibleRect.height > 15 && replaceAll.visibleRect.height > 15)
            document.setTextUndoably("banana banana", actionName: "Fixture"); await pump()
            search.stringValue = "ana"; replacement.stringValue = "X"; regex.state = .off
            replaceAll.performClick(nil); await pump()
            check("find bar literal replace all", document.storage.string == "bXna bXna")
            document.setTextUndoably("abc abc", actionName: "Fixture"); await pump()
            search.stringValue = "(?<=a)bc"; replacement.stringValue = "Y"; regex.state = .on
            view.setSelectedRange(NSRange(location: 1, length: 2))
            replaceOne.performClick(nil); await pump()
            check("find bar regex replace one with context", document.storage.string == "aY abc")
            regex.state = .off
        } else { check("find bar controls available", false) }
        _ = delegate.executeCommand("command_palette"); await pump()
        check("command palette opens", delegate.snapshot["paletteVisible"] as? Bool == true)
        _ = delegate.executeCommand("dismiss_palette")
        _ = delegate.executeCommand("quick_open"); await pump()
        check("quick open panel opens", delegate.snapshot["paletteVisible"] as? Bool == true)
        _ = delegate.executeCommand("dismiss_palette")
        delegate.window.makeKeyAndOrderFront(nil); delegate.window.makeFirstResponder(view)
        delegate.runBuild(spec: BuildSpec(argv: ["/usr/bin/python3", "-c", "import sys; print('构建 stdout'); print('stderr',file=sys.stderr)"], timeoutSeconds: 5))
        check("build completes", await awaitIdle("buildRunning"))
        check("build output pane", (delegate.snapshot["output"] as? String ?? "").contains("构建 stdout") && (delegate.snapshot["output"] as? String ?? "").contains("stderr"))
        let log = delegate.snapshot["buildLog"] as? String ?? ""
        check("complete build log retained", FileManager.default.fileExists(atPath: log))
        delegate.runBuild(spec: BuildSpec(argv: ["/usr/bin/python3", "-c", "import time; time.sleep(20)"], timeoutSeconds: 25))
        await pump(0.15); _ = delegate.executeCommand("cancel_build")
        check("build cancellation completes", await awaitIdle("buildRunning", timeout: 3))
        let plugin = Bundle.main.resourceURL!.appendingPathComponent("plugin_host/demo_plugin.py")
        document.setTextUndoably("abc 😀", actionName: "Fixture"); await pump(); document.undoManager.removeAllActions()
        view.setSelectedRange(NSRange(location: 0, length: 3))
        delegate.runPlugin(pythonURL: URL(fileURLWithPath: "/usr/bin/python3"), pluginURL: plugin, command: "reverse_selection")
        check("plugin completes", await awaitIdle("pluginRunning"))
        check("plugin snapshot applied", document.storage.string == "cba 😀")
        document.undoManager.undo(); await pump()
        check("plugin single undo", document.storage.string == "abc 😀")
        delegate.runPlugin(pythonURL: URL(fileURLWithPath: "/usr/bin/python3"), pluginURL: plugin, command: "missing_command")
        check("plugin failure completes", await awaitIdle("pluginRunning"))
        check("plugin failure leaves document intact", document.storage.string == "abc 😀" && (delegate.snapshot["output"] as? String ?? "").contains("Plugin failed"))
        do {
            let slow = directory.appendingPathComponent("slow_plugin.py")
            try "import time\nimport sublime_plugin\nclass SlowCommand(sublime_plugin.TextCommand):\n def run(self, edit):\n  time.sleep(0.3)\n  self.view.insert(edit, 0, 'STALE')\n".write(to: slow, atomically: true, encoding: .utf8)
            delegate.runPlugin(pythonURL: URL(fileURLWithPath: "/usr/bin/python3"), pluginURL: slow, command: "slow")
            document.setTextUndoably("user edit", actionName: "User"); await pump(0.1)
            check("stale plugin completes", await awaitIdle("pluginRunning"))
            check("stale plugin result discarded", document.storage.string == "user edit")
            let lookaround = try SearchEngine.replacing(in: "abc abc", query: "(?<=a)bc", replacement: "X", regex: true, caseSensitive: true, range: NSRange(location: 1, length: 2))
            check("single regex replacement retains context", lookaround.text == "aX abc")
        } catch { check("stale plugin and context", false); print(error) }
        do {
            let sessionURL = directory.appendingPathComponent("ui-session.json")
            let session = delegate.sessionSnapshot
            try session.save(sessionURL)
            for openDocument in delegate.documents { openDocument.checkpoint() }
            let restored = delegate.restoreSession(try EditorSession.load(sessionURL))
            check("session restores tabs and split", restored && delegate.documents.count == 2 && delegate.snapshot["paneCount"] as? Int == 2)
            check("session restores unsaved text", delegate.currentDocument?.storage.string == "user edit" && delegate.currentDocument?.isModified == true)
            let project = directory.appendingPathComponent("ui-project.json")
            try JSONSerialization.data(withJSONObject: ["folders": [["path": "."]], "custom": ["preserved": true]]).write(to: project)
            delegate.openProject(try EditorProject.load(project))
            await pump(0.2)
            check("project file opens folder", (delegate.snapshot["projectFiles"] as? Int ?? 0) >= 2)
        } catch { check("session/project UI", false); print(error) }
        do {
            delegate.selectDocument(0)
            delegate.currentDocument?.setTextUndoably("// Independent editor\nimport Foundation\n\nlet greeting = \"你好，世界 😀\"\nprint(greeting)\n", actionName: "Capture")
            // This fixture checks two views of one file; ordinary tab switching
            // now replaces only the active pane and may show different files.
            _ = delegate.executeCommand("single_pane")
            _ = delegate.executeCommand("split_right")
            await pump(0.3)
            delegate.window.contentView?.layoutSubtreeIfNeeded()
            let actualViews = textViews(delegate.window.contentView!).filter { $0.textStorage === delegate.currentDocument?.storage }
            check("tab switch owns current text view", delegate.currentTextView?.textStorage === delegate.currentDocument?.storage && delegate.currentDocument?.displayName == "first.swift")
            let keyword = (delegate.currentDocument!.storage.string as NSString).range(of: "import").location
            check("basic syntax coloring in split views", actualViews.count == 2 && actualViews.allSatisfy {
                $0.layoutManager?.temporaryAttributes(atCharacterIndex: keyword, effectiveRange: nil)[.foregroundColor] != nil
            })
            print("DETAIL live editor frames \(actualViews.map { $0.frame })")
            for editor in actualViews {
                var cursor: NSView? = editor
                var frames: [String] = []
                while let current = cursor { frames.append("\(type(of: current)):frame=\(current.frame),bounds=\(current.bounds)"); cursor = current.superview }
                print("DETAIL ancestors \(frames)")
            }
            check("visible editor has viewport", actualViews.count == 2 && actualViews.allSatisfy { $0.frame.width > 100 && $0.frame.height > 100 && $0.visibleRect.height > 100 })
            try captureWindow("window.png")
            if !log.isEmpty { try FileManager.default.copyItem(at: URL(fileURLWithPath: log), to: directory.appendingPathComponent("build.log")) }
            try JSONSerialization.data(withJSONObject: delegate.snapshot, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("snapshot.json"))
            check("own window image captured", FileManager.default.fileExists(atPath: directory.appendingPathComponent("window.png").path))
        } catch { check("capture window", false); print(error) }
        let lifecycle = await LifecycleUITests.run(delegate: delegate, directory: directory)
        passed += lifecycle.passed; failed += lifecycle.failed
        let context = await ContextMenuUITests.run(delegate: delegate, directory: directory)
        passed += context.passed; failed += context.failed
        let windows = await MultiWindowUITests.run(delegate: delegate, directory: directory)
        passed += windows.passed; failed += windows.failed
        print("UI tests: \(passed) passed, \(failed) failed")
        delegate.window.orderOut(nil)
        return failed == 0 ? 0 : 1
    }
}
