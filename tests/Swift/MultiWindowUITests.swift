import AppKit

enum MultiWindowUITests {
    @MainActor static func run(delegate first: EditorWorkspace, directory: URL) async -> (passed: Int, failed: Int) {
        var passed = 0, failed = 0
        func check(_ name: String, _ value: Bool) {
            if value { passed += 1; print("PASS \(name)") }
            else { failed += 1; print("FAIL \(name)") }
        }
        func pump(_ seconds: Double = 0.15) async {
            if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: NSApp.keyWindow?.windowNumber ?? first.window.windowNumber,
                context: nil, subtype: 0, data1: 0, data2: 0) { NSApp.postEvent(event, atStart: false) }
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        func key(_ value: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: NSApp.modalWindow?.windowNumber ?? NSApp.keyWindow?.windowNumber ?? first.window.windowNumber,
                    context: nil, characters: value, charactersIgnoringModifiers: modifiers.contains(.shift) ? value.uppercased() : value.lowercased(), isARepeat: false, keyCode: code) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
        }
        func menuAction(_ menu: String, _ title: String) -> Bool {
            guard let submenu = NSApp.mainMenu?.items.first(where: { $0.title == menu })?.submenu,
                  let item = submenu.items.first(where: { $0.title == title }), let action = item.action else { return false }
            return NSApp.sendAction(action, to: item.target, from: item)
        }
        func waitSheet(_ parent: NSWindow) async -> NSWindow? {
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if let sheet = parent.attachedSheet, NSApp.modalWindow === sheet { return sheet }
                await pump(0.03)
            }
            return nil
        }
        func waitDismissed(_ parent: NSWindow) async -> Bool {
            let deadline = Date().addingTimeInterval(3)
            while parent.attachedSheet != nil && Date() < deadline { await pump(0.03) }
            return parent.attachedSheet == nil
        }
        guard let app = NSApp.delegate as? EditorAppDelegate else {
            check("application owns workspace windows", false)
            return (passed, failed)
        }
        check("application owns workspace windows", app.workspaces.count == 1 && app.workspaces.first === first)
        let originalDocument = first.currentDocument
        let originalText = originalDocument?.storage.string
        for document in first.documents { document.checkpoint() }
        first.window.makeKeyAndOrderFront(nil)
        first.window.makeFirstResponder(first.currentTextView)
        await pump()
        if let menu = NSApp.mainMenu?.items.first(where: { $0.title == "File" })?.submenu,
           let item = menu.items.first(where: { $0.title == "New Window" }) {
            print("DETAIL New Window key=\(item.keyEquivalent) modifiers=\(item.keyEquivalentModifierMask.rawValue) enabled=\(item.isEnabled) target=\(String(describing: item.target)) keyWindow=\(NSApp.keyWindow?.windowNumber ?? 0)")
        }
        key("N", code: 45, modifiers: [.command, .shift]); await pump(0.3)
        check("New Window shortcut creates a workspace in the same application", app.workspaces.count == 2)
        guard let second = app.workspaces.last, second !== first else { return (passed, failed) }
        let ownIdentifier = Bundle.main.bundleIdentifier!
        func ownRunningApps() -> [NSRunningApplication] {
            NSRunningApplication.runningApplications(withBundleIdentifier: ownIdentifier).filter { !$0.isTerminated }
        }
        check("multiple workspace windows share one running app and Dock identity", ownRunningApps().count == 1 && ownRunningApps().first?.processIdentifier == ProcessInfo.processInfo.processIdentifier)
        check("new windows fold into native window tabs", first.window.tabbedWindows?.count == 2 && first.window.tabbedWindows?.contains(second.window) == true)
        check("new workspace has independent documents", second.documents.count == 1 && second.currentDocument !== originalDocument && second.currentDocument?.storage.string == "")
        check("new workspace inherits current theme and font", second.snapshot["theme"] as? String == first.snapshot["theme"] as? String && second.currentTextView?.font?.pointSize == first.currentTextView?.font?.pointSize)
        check("active window owns menu actions", app.activeWorkspace === second && NSApp.mainMenu?.items.first(where: { $0.title == "File" })?.submenu?.items.first(where: { $0.title == "Save" })?.target as? EditorWorkspace === second)
        check("native window-tab plus action is handled by the responder chain", NSApp.sendAction(#selector(EditorAppDelegate.newWindowForTab(_:)), to: nil, from: nil) && app.workspaces.count == 3)
        if let extra = app.workspaces.last, extra !== second && extra !== first {
            check("plus action adds a tab to the existing workspace group", extra.window.tabbedWindows?.count == 3)
            extra.window.performClose(nil)
            second.window.makeKeyAndOrderFront(nil)
            await pump()
        } else { check("plus action adds a tab to the existing workspace group", false) }
        let oldColor = first.currentTextView?.backgroundColor
        let oldTabSize = first.currentDocument?.settings.tabSize
        let theme = first.snapshot["theme"] as? String == "light" ? "Dark" : "Light"
        if let menu = NSApp.mainMenu?.items.first(where: { $0.title == "Preferences" })?.submenu?.items.first(where: { $0.title == "Theme" })?.submenu,
           let index = menu.items.firstIndex(where: { $0.title == theme }) {
            menu.performActionForItem(at: index)
            check("theme change updates every workspace's actual editor colors", first.currentTextView?.backgroundColor != oldColor && first.currentTextView?.backgroundColor == second.currentTextView?.backgroundColor)
        } else { check("theme change updates every workspace's actual editor colors", false) }
        let fontSize = first.currentTextView?.font?.pointSize ?? 0
        if let menu = NSApp.mainMenu?.items.first(where: { $0.title == "View" })?.submenu?.items.first(where: { $0.title == "Font" })?.submenu,
           let index = menu.items.firstIndex(where: { $0.title == "Larger" }) {
            menu.performActionForItem(at: index)
            check("font preferences update all workspaces without resetting indentation", first.currentTextView?.font?.pointSize == fontSize + 1 && second.currentTextView?.font?.pointSize == fontSize + 1 && first.currentDocument?.settings.tabSize == oldTabSize)
        } else { check("font preferences update all workspaces without resetting indentation", false) }
        do {
            let file = directory.appendingPathComponent("multi-window.txt")
            let forwarded = directory.appendingPathComponent("forwarded.txt")
            try Data("second window\n".utf8).write(to: file)
            try Data("delivered by LaunchServices\n".utf8).write(to: forwarded)
            second.openDocument(file)
            check("path menu operates on selected window", menuAction("File", "Copy File Path") && NSPasteboard.general.string(forType: .string) == file.path)
            first.window.makeKeyAndOrderFront(nil); await pump()
            check("switching window tabs changes menu target", app.activeWorkspace === first && menuAction("File", "Copy File Path") && NSPasteboard.general.string(forType: .string) == originalDocument?.fileURL?.path)
            check("edits in another window leave the first document intact", originalDocument?.storage.string == originalText)
            second.window.makeKeyAndOrderFront(nil); await pump()
            check("window tab can detach through native Window menu", menuAction("Window", "Move Window Tab to New Window"))
            await pump()
            check("detached windows stay in one application", app.workspaces.count == 2 && first.window.tabbedWindows?.contains(second.window) != true && ownRunningApps().count == 1)
            check("Merge All Windows menu executes", menuAction("Window", "Merge All Windows")); await pump()
            check("merge folds detached windows into one native tab group", first.window.tabbedWindows?.count == 2 && second.window.tabbedWindows?.contains(first.window) == true)

            second.window.makeKeyAndOrderFront(nil); await pump()
            check("file forwarding fixture selects the receiving workspace", app.activeWorkspace === second)
            let subprocess = Process()
            subprocess.executableURL = Bundle.main.executableURL
            subprocess.arguments = ["--project", directory.path, forwarded.path]
            let output = Pipe(), error = Pipe()
            subprocess.standardOutput = output; subprocess.standardError = error
            try subprocess.run()
            let deadline = Date().addingTimeInterval(12)
            while subprocess.isRunning && Date() < deadline { await pump(0.05) }
            if subprocess.isRunning { subprocess.terminate() }
            check("direct relaunch forwards files and exits", !subprocess.isRunning && subprocess.terminationStatus == 0)
            if !subprocess.isRunning {
                let message = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if !message.isEmpty { print("DETAIL relaunch \(message)") }
            }
            let deliveryDeadline = Date().addingTimeInterval(3)
            while second.currentDocument?.fileURL != forwarded && Date() < deliveryDeadline { await pump(0.03) }
            print("DETAIL forwarded window=\(app.activeWorkspace?.window.windowNumber ?? 0) file=\(second.currentDocument?.fileURL?.lastPathComponent ?? "nil") project=\(second.snapshot["projectRoot"] ?? "nil")")
            check("relaunch delivers files and project to active workspace", second.currentDocument?.fileURL == forwarded && second.snapshot["projectRoot"] as? String == directory.path)
            check("relaunch leaves one Dock application and two workspace windows", ownRunningApps().count == 1 && app.workspaces.count == 2)
            first.window.makeKeyAndOrderFront(nil); await pump()
            let count = first.documents.count + second.documents.count
            app.application(NSApp, openFiles: [file.path]); await pump()
            check("external file open focuses its existing owning window", app.activeWorkspace === second && second.currentDocument?.fileURL == file && first.documents.count + second.documents.count == count)

            guard let document = second.currentDocument else { throw EditorFailure.invalidEdit("No second document") }
            document.setTextUndoably("unsaved second window", actionName: "Fixture")
            second.window.makeKeyAndOrderFront(nil)
            key("W", code: 13, modifiers: [.command, .shift])
            let closeSheet = await waitSheet(second.window)
            check("Close Window asks about its own modified document", closeSheet != nil)
            if closeSheet != nil { key("\u{1b}", code: 53) }
            let canceledClose = await waitDismissed(second.window)
            check("canceling window close preserves both workspaces and edits", canceledClose && app.workspaces.count == 2 && document.storage.string == "unsaved second window" && second.currentTextView?.isEditable == true)
            first.window.makeKeyAndOrderFront(nil); await pump()
            key("q", code: 12, modifiers: .command)
            let quitSheet = await waitSheet(second.window)
            check("Quit checks modified documents in another workspace", quitSheet != nil && quitSheet?.sheetParent === second.window)
            if quitSheet != nil { key("\u{1b}", code: 53) }
            let canceledQuit = await waitDismissed(second.window)
            check("canceling Quit leaves all windows editable", canceledQuit && app.workspaces.count == 2 && first.currentTextView?.isEditable == true && second.currentTextView?.isEditable == true && document.isModified)
            if let cgImage = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(second.window.windowNumber), [.boundsIgnoreFraming, .bestResolution]),
               let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) {
                try data.write(to: directory.appendingPathComponent("window-tabs.png"))
                check("native window tab screenshot captured", true)
            } else { check("native window tab screenshot captured", false) }
            for document in second.documents { document.checkpoint() }
            second.runBuild(spec: BuildSpec(argv: ["/bin/sleep", "30"], timeoutSeconds: 35))
            await pump()
            check("workspace close fixture has running work", second.hasRunningWork)
            second.window.performClose(nil)
            check("workspace remains owned while build cancellation finishes", app.workspaces.contains(where: { $0 === second }) && second.currentTextView?.isEditable == false)
            let closeDeadline = Date().addingTimeInterval(4)
            while app.workspaces.contains(where: { $0 === second }) && Date() < closeDeadline { await pump(0.03) }
            check("workspace close finishes cancellation before releasing ownership", !second.hasRunningWork && !app.workspaces.contains(where: { $0 === second }))
            await pump()
            check("closing one workspace preserves the remaining window", app.workspaces.count == 1 && app.workspaces.first === first && first.window.isVisible)
            first.window.makeKeyAndOrderFront(nil); await pump()
            if let originalDocument, let index = first.documents.firstIndex(where: { $0 === originalDocument }) { first.selectDocument(index) }
            check("remaining window receives menu actions after close", menuAction("File", "Copy File Path") && NSPasteboard.general.string(forType: .string) == originalDocument?.fileURL?.path)
            first.window.performClose(nil); await pump()
            check("closing last window retains application for Dock reopen", app.workspaces.isEmpty && !app.applicationShouldTerminateAfterLastWindowClosed(NSApp) && ownRunningApps().count == 1)
            check("Release Notes menu works without an editor workspace", menuAction("Source Editor", "Release Notes…") &&
                  app.projectInformationWindow?.window?.isVisible == true && app.workspaces.isEmpty)
            app.projectInformationWindow?.window?.performClose(nil)
            check("Project introduction works without an editor workspace", menuAction("Source Editor", "About Source Editor") &&
                  app.projectInformationWindow?.section == .about && app.workspaces.isEmpty)
            app.projectInformationWindow?.window?.performClose(nil)
            check("New Window menu works without an open workspace", menuAction("File", "New Window")); await pump()
            check("empty application creates a new usable workspace", app.workspaces.count == 1 && app.activeWorkspace?.currentTextView?.isEditable == true)
            app.activeWorkspace?.window.performClose(nil); await pump()
            _ = app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false); await pump()
            check("Dock reopen creates a workspace after last close", app.workspaces.count == 1 && app.activeWorkspace?.window.isVisible == true)
            app.activeWorkspace?.window.performClose(nil); await pump()
        } catch { check("multi-window workflow", false); print("DETAIL multi-window error \(error)") }
        for workspace in app.workspaces where workspace !== first {
            if let sheet = NSApp.modalWindow, sheet.sheetParent === workspace.window { NSApp.abortModal(); await pump() }
            for document in workspace.documents { document.checkpoint() }
            workspace.window.performClose(nil)
        }
        print("Multi-window UI tests: \(passed) passed, \(failed) failed")
        return (passed, failed)
    }
}
