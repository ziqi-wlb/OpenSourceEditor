import AppKit

enum TypingUITests {
    private final class EditRecorder: NSObject {
        var ranges: [NSRange] = []
        init(storage: NSTextStorage) {
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(record(_:)),
                name: NSTextStorage.didProcessEditingNotification, object: storage)
        }
        @objc private func record(_ notification: Notification) {
            guard let storage = notification.object as? NSTextStorage,
                  storage.editedMask.contains(.editedCharacters) else { return }
            ranges.append(storage.editedRange)
        }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
    @MainActor static func run(directory: URL) async -> Int32 {
        var passed = 0, failures: [String] = [], traces: [[String: Any]] = []
        func check(_ name: String, _ value: Bool) {
            if value { passed += 1 } else { failures.append(name) }
        }
        func pump() async { try? await Task.sleep(nanoseconds: 300_000_000) }
        func capture(_ workspace: EditorWorkspace, _ name: String) throws {
            if let image = CGWindowListCreateImage(.null, .optionIncludingWindow,
                CGWindowID(workspace.window.windowNumber), .boundsIgnoreFraming) {
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name))
            }
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let path = directory.appendingPathComponent("long-list.md")
            let original = "# Work notes\n" + (1...300).map { "\($0). Work item 中文😀 \($0)\n" }.joined()
            try original.write(to: path, atomically: true, encoding: .utf8)
            let app = EditorAppDelegate(recentFiles: RecentLocations(defaults: nil),
                desktopStore: EditorDesktopStore(directory: directory.appendingPathComponent("state")),
                recentFolders: RecentLocations(defaults: nil, kind: .folders))
            let workspace = app.newWindow(openURLs: [path], tabbed: false)
            workspace.window.setContentSize(NSSize(width: 1000, height: 650))
            var dark = EditorConfiguration(); dark.theme = "dark"; workspace.applyConfiguration(dark)
            let document = workspace.currentDocument!, view = workspace.currentTextView!
            NSApp.activate(ignoringOtherApps: true)
            workspace.window.makeKeyAndOrderFront(nil)
            let focusDeadline = Date().addingTimeInterval(2)
            while !(NSApp.isActive && NSApp.keyWindow === workspace.window), Date() < focusDeadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            check("Typing fixture owns the active native window", NSApp.isActive && NSApp.keyWindow === workspace.window)
            // Finish initial window geometry and the small fixture's paragraph
            // layout before measuring a later edit, not an initial display pass.
            workspace.window.contentView?.layoutSubtreeIfNeeded()
            if let container = view.textContainer { view.layoutManager?.ensureLayout(for: container) }
            workspace.window.displayIfNeeded(); await pump()
            workspace.window.makeFirstResponder(view)
            let source = original as NSString
            let row = source.range(of: "275. Work item 中文😀 275")
            let caret = NSMaxRange(row)
            view.setSelectedRange(NSRange(location: caret, length: 0)); view.scrollRangeToVisible(view.selectedRange())
            await pump()
            let before = view.enclosingScrollView!.contentView.bounds.origin
            check("Fixture shows a numbered line far below the start", before.y > 1000)
            document.undoManager.removeAllActions()
            let recorder = EditRecorder(storage: document.storage)
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: workspace.window.windowNumber,
                context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
            let selectionBeforeReturn = view.selectedRanges.map(\.rangeValue)
            let textBeforeReturn = document.textSnapshot
            check("Initial presentation leaves the fixture text unchanged", textBeforeReturn == original)
            document.undoManager.beginUndoGrouping(); view.keyDown(with: event); document.undoManager.endUndoGrouping()
            let textAfterReturn = document.textSnapshot
            let after = view.enclosingScrollView!.contentView.bounds.origin
            let expectedCaret = caret + 6 // newline and "276. "
            check("Return continues numbered Markdown with the right caret", view.selectedRange() == NSRange(location: expectedCaret, length: 0) && document.storage.string.contains("275. Work item 中文😀 275\n276. \n276. Work"))
            check("Return changes only the edited line's storage range", !recorder.ranges.isEmpty && recorder.ranges.allSatisfy { $0.location >= row.location && $0.length < 100 })
            check("Return preserves the scrolled viewport immediately", after.y > 1000 && abs(after.y - before.y) < 100)
            await pump()
            let settled = view.enclosingScrollView!.contentView.bounds.origin
            check("Delayed highlight keeps caret visible and avoids the first line", settled.y > 1000 && abs(settled.y - before.y) < 100)
            let numberColor = view.layoutManager!.temporaryAttribute(.foregroundColor, atCharacterIndex: caret + 1, effectiveRange: nil) as? NSColor
            check("Markdown list numbers do not receive code-number coloring", numberColor == nil)
            check("Typing keeps the configured base font", (document.storage.attribute(.font, at: caret + 1, effectiveRange: nil) as? NSFont)?.pointSize == view.typingAttributes[.font].flatMap { ($0 as? NSFont)?.pointSize })
            traces.append(["before_y": before.y, "immediate_y": after.y, "settled_y": settled.y,
                "caret": view.selectedRange().location, "number_color": numberColor?.description ?? "base foreground",
                "selection_before_return": selectionBeforeReturn.map { [$0.location, $0.length] },
                "line_ending": document.settings.lineEnding.text.debugDescription,
                "before_return_prefix": String(textBeforeReturn.prefix(40)),
                "before_return_excerpt": (textBeforeReturn as NSString).substring(with: NSRange(location: row.location, length: min(100, (textBeforeReturn as NSString).length - row.location))),
                "original_matches_before_undo": textAfterReturn == original,
                "return_excerpt": (textAfterReturn as NSString).substring(with: NSRange(location: row.location, length: min(100, (textAfterReturn as NSString).length - row.location))),
                "character_edit_ranges": recorder.ranges.map { [$0.location, $0.length] }])
            try capture(workspace, "numbered-return.png")
            document.undoManager.undo(); await pump()
            check("One undo restores list content, caret and viewport", document.storage.string == original && view.selectedRange().location == caret && view.enclosingScrollView!.contentView.bounds.minY > 1000)
            document.undoManager.redo(); await pump()
            check("Redo restores the continued list and visible caret", view.selectedRange().location == expectedCaret && view.enclosingScrollView!.contentView.bounds.minY > 1000)
            var light = EditorConfiguration(); light.theme = "light"
            workspace.applyConfiguration(light); view.scrollRangeToVisible(view.selectedRange()); await pump()
            check("Light theme preserves Markdown number styling", view.layoutManager!.temporaryAttribute(.foregroundColor, atCharacterIndex: caret + 1, effectiveRange: nil) == nil)
            try capture(workspace, "numbered-return-light.png")
            _ = workspace.executeCommand("split_right")
            let companion = workspace.paneViewsForTesting[0], active = workspace.paneViewsForTesting[1]
            companion.setSelectedRange(NSRange(location: 1000, length: 0)); companion.scrollRangeToVisible(companion.selectedRange())
            active.setSelectedRange(NSRange(location: expectedCaret, length: 0)); active.scrollRangeToVisible(active.selectedRange())
            workspace.window.makeFirstResponder(active); await pump()
            let companionBefore = companion.enclosingScrollView!.contentView.bounds.minY
            document.undoManager.beginUndoGrouping(); active.insertTab(nil); document.undoManager.endUndoGrouping()
            await pump()
            check("Custom Tab leaves the other split's cursor and viewport intact", companion.selectedRange().location == 1000 && abs(companion.enclosingScrollView!.contentView.bounds.minY - companionBefore) < 2)
            check("Custom Tab keeps the active pane below the first line", active.enclosingScrollView!.contentView.bounds.minY > 1000)
            document.undoManager.undo(); await pump()
            check("Split Tab undo keeps both views attached to the same document", companion.string == active.string && active.selectedRange().location == expectedCaret)
            _ = workspace.executeCommand("single_pane")
            for suffix in ["txt", "swift"] {
                let file = directory.appendingPathComponent("long-text." + suffix)
                try original.write(to: file, atomically: true, encoding: .utf8)
                _ = workspace.openDocument(file)
                let text = workspace.currentTextView!, fileDocument = workspace.currentDocument!
                text.setSelectedRange(NSRange(location: caret, length: 0)); text.scrollRangeToVisible(text.selectedRange()); await pump()
                let origin = text.enclosingScrollView!.contentView.bounds.minY
                text.insertNewline(nil); await pump()
                check("Return preserves " + suffix + " viewport and caret", abs(text.enclosingScrollView!.contentView.bounds.minY - origin) < 100 && text.selectedRange().location == caret + 1)
                if suffix == "swift" {
                    let color = text.layoutManager!.temporaryAttribute(.foregroundColor, atCharacterIndex: row.location, effectiveRange: nil) as? NSColor
                    check("Source-code numeric tokens retain their syntax color", color == NSColor.systemOrange)
                }
                fileDocument.undoManager.undo(); await pump()
                check("Return undo preserves " + suffix + " text", fileDocument.storage.string == original)
            }
            workspace.window.close()
        } catch { failures.append(error.localizedDescription) }
        let output: [String: Any] = ["passed": passed, "failed": failures.count, "failures": failures, "traces": traces]
        let data = try! JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        try? data.write(to: directory.appendingPathComponent("results.json"))
        print(String(decoding: data, as: UTF8.self)); return failures.isEmpty ? 0 : 1
    }
}
