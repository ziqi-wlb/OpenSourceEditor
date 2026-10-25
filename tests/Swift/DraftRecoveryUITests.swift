import AppKit

/// Real windows and sheets, isolated Application Support, and process restart.
enum DraftRecoveryUITests {
    @MainActor static func run(directory: URL) async -> Int32 {
        var passed = 0, failures: [String] = []
        func check(_ name: String, _ value: Bool) { if value { passed += 1 } else { failures.append(name); print("FAIL: " + name) } }
        func wait(_ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline { if condition() { return true }; try? await Task.sleep(nanoseconds: 20_000_000) }
            return condition()
        }
        // Trigger modal actions through AppKit's loop; use an independent timer
        // in modalPanel mode to click the actual owned sheet button.
        func choose(_ title: String, workspace: EditorWorkspace, action: @escaping () -> Void) async -> Bool {
            var selected = false, finished = false
            let deadline = Date().addingTimeInterval(5)
            func buttons(_ view: NSView) -> [NSButton] {
                (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
            }
            let timer = Timer(timeInterval: 0.02, repeats: true) { timer in
                MainActor.assumeIsolated {
                if let sheet = workspace.window.attachedSheet, NSApp.modalWindow === sheet,
                   let content = sheet.contentView, let button = buttons(content).first(where: { $0.title == title }) {
                    selected = true; timer.invalidate(); button.performClick(nil)
                } else if Date() > deadline {
                    timer.invalidate()
                    if NSApp.modalWindow?.sheetParent === workspace.window { NSApp.abortModal() }
                }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(timer, forMode: .modalPanel)
            DispatchQueue.main.async { action(); finished = true }
            let result = await wait { finished && workspace.window.attachedSheet == nil }
            timer.invalidate()
            return result && selected
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let store = EditorDesktopStore(directory: directory.appendingPathComponent("support"))
            let app = EditorAppDelegate(recentFiles: RecentLocations(defaults: nil), desktopStore: store)
            let file = directory.appendingPathComponent("original.md")
            try "# Original 中文😀".write(to: file, atomically: true, encoding: .utf8)
            let source = try Data(contentsOf: file)
            let workspace = app.newWindow(openURLs: [file])
            workspace.activateMenus()
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let tabClose = descendants(workspace.window.contentView!).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Close original.md" }
            check("Tab close uses accessible SF Symbol", tabClose?.image != nil && tabClose?.accessibilityLabel() == "Close original.md")
            let fontMenu = NSApp.mainMenu?.item(withTitle: "Preferences")?.submenu?.item(withTitle: "Editor Font")?.submenu
            check("Font chooser offers installed monospaced families", fontMenu?.items.contains(where: { $0.title == "Menlo" }) == true)
            let fontSource = workspace.currentDocument!.storage.string
            if let systemItem = fontMenu?.items.first(where: { $0.title == "System Monospaced" }), let action = systemItem.action {
                _ = NSApp.sendAction(action, to: systemItem.target, from: systemItem)
            }
            check("Font selection applies without editing source", workspace.currentTextView?.font?.fontName == NSFont.monospacedSystemFont(ofSize: 12, weight: .regular).fontName && workspace.currentDocument?.storage.string == fontSource && workspace.currentDocument?.isModified == false)
            check("Font choice persists through desktop store", (try store.loadConfiguration())?.fontName == workspace.currentTextView?.font?.fontName)
            workspace.setAutoRecovery(true, directory: app.recoveryDirectory)
            let url = workspace.recoveryURLForTesting!
            workspace.currentDocument!.setTextUndoably("# Earlier draft", actionName: "Fixture")
            workspace.updateRecoveryForTesting()
            workspace.currentDocument!.setTextUndoably("# Last draft 中文😀", actionName: "Fixture")
            workspace.currentTextView!.setSelectedRange(NSRange(location: 2, length: 4))
            check("Keep Drafts is an owned close sheet", await choose("Keep Drafts", workspace: workspace) { workspace.window.performClose(nil) })
            check("Normal window close waits for final snapshot", await wait { !workspace.window.isVisible && workspace.recoveryURLForTesting == nil })
            let retained = try EditorSession.load(url)
            check("Close keeps latest edit and selection", retained.closedNormally == true && retained.documents[0].text == "# Last draft 中文😀" && retained.documents[0].selections == [[2, 4]])
            check("Backup never changes original bytes", try Data(contentsOf: file) == source)
            check("Closed drafts discoverable", RecoveryCandidate.discover(in: app.recoveryDirectory).contains { $0.url == url })
            let nextApp = EditorAppDelegate(recentFiles: RecentLocations(defaults: nil), desktopStore: store)
            nextApp.launch(openURLs: [], projectURL: nil)
            let restored = nextApp.workspaces.first { $0.documents.contains { $0.storage.string == "# Last draft 中文😀" } }!
            check("Normal restart automatically restores closed-window draft", restored.currentDocument?.isModified == true && restored.currentDocument?.fileURL == file.standardizedFileURL)
            check("Restore transfers backup before deleting old copy", await wait { !FileManager.default.fileExists(atPath: url.path) && restored.recoveryURLForTesting.flatMap { try? EditorSession.load($0) }?.documents[0].text == "# Last draft 中文😀" })
            check("Cancel close preserves document and editable state", await choose("Cancel", workspace: restored) { restored.window.performClose(nil) } && restored.window.isVisible && restored.currentTextView?.isEditable == true)
            check("Revert discards draft and reloads disk", await choose("Revert", workspace: restored) { _ = restored.executeCommand("revert") } && restored.currentDocument?.storage.string == "# Original 中文😀" && restored.currentDocument?.isModified == false)
            let restoredURL = restored.recoveryURLForTesting!
            check("Revert clears backup promptly", await wait { !FileManager.default.fileExists(atPath: restoredURL.path) })
            restored.currentDocument!.setTextUndoably("Discard me", actionName: "Fixture")
            restored.updateRecoveryForTesting()
            check("Discard close is explicit", await choose("Discard Drafts", workspace: restored) { restored.window.performClose(nil) })
            check("Discard deletes queued backup and leaves source unchanged", await wait { !restored.window.isVisible && !FileManager.default.fileExists(atPath: restoredURL.path) } && (try? Data(contentsOf: file)) == source)

            let external = app.newWindow(openURLs: [file])
            external.currentDocument!.setTextUndoably("# Protected draft", actionName: "Fixture")
            let externalSnapshot = app.recoveryDirectory.appendingPathComponent("external.json")
            try external.sessionSnapshot.save(externalSnapshot)
            let imported = directory.appendingPathComponent("imported-session.json")
            try external.sessionSnapshot.save(imported)
            let importedBytes = try Data(contentsOf: imported)
            let importedWindow = try external.restoreRecoverySnapshot(imported)
            check("Import creates backup in owned support directory", importedWindow.recoveryURLForTesting?.deletingLastPathComponent() == app.recoveryDirectory)
            check("Imported session is retained byte-for-byte", await wait { importedWindow.recoveryURLForTesting.flatMap { try? EditorSession.load($0) } != nil } && (try? Data(contentsOf: imported)) == importedBytes)
            try "# New external content".write(to: file, atomically: true, encoding: .utf8)
            let detached = try external.restoreRecoverySnapshot(externalSnapshot)
            check("Changed disk recovers into detached dirty buffer", detached.currentDocument?.fileURL == nil && detached.currentDocument?.storage.string == "# Protected draft" && detached.currentDocument?.isModified == true)
            check("External bytes unchanged by restore", (try String(contentsOf: file)) == "# New external content")
            let discardFile = app.recoveryDirectory.appendingPathComponent("discard.json")
            try external.sessionSnapshot.save(discardFile)
            let originals = try external.discardRecoverySnapshot(discardFile)
            check("Discard recovery opens current originals", originals.currentDocument?.storage.string == "# New external content" && originals.currentDocument?.isModified == false && !FileManager.default.fileExists(atPath: discardFile.path))
            let corrupt = app.recoveryDirectory.appendingPathComponent("corrupt.json")
            try Data("{broken".utf8).write(to: corrupt)
            do { _ = try external.discardRecoverySnapshot(corrupt); check("Malformed backup retained", false) }
            catch { check("Malformed backup retained", FileManager.default.fileExists(atPath: corrupt.path)) }

            let blocked = directory.appendingPathComponent("not-a-directory")
            try Data().write(to: blocked)
            let failed = app.newWindow(openURLs: [file])
            failed.setAutoRecovery(true, directory: blocked)
            failed.currentDocument!.setTextUndoably("Keep on failed write", actionName: "Fixture")
            check("Failure close invokes Keep Drafts", await choose("Keep Drafts", workspace: failed) { failed.window.performClose(nil) })
            check("Failed close re-enables editing and retains owner", await wait { failed.currentTextView?.isEditable == true && failed.recoveryMessageForTesting.contains("failed") } && failed.window.isVisible && failed.currentDocument?.storage.string == "Keep on failed write" && failed.recoveryURLForTesting != nil)
            try FileManager.default.removeItem(at: blocked)
            check("Close can retry after disk failure", await choose("Keep Drafts", workspace: failed) { failed.window.performClose(nil) })
            check("Retry persists the draft", await wait { !failed.window.isVisible } && RecoveryCandidate.discover(in: blocked).count == 1)
            for owner in [app, nextApp] {
                for item in owner.workspaces {
                    for document in item.documents { document.checkpoint() }
                    item.window.performClose(nil)
                }
                _ = await wait { owner.workspaces.isEmpty }
            }
        } catch { failures.append(error.localizedDescription) }
        print(String(decoding: try! JSONSerialization.data(withJSONObject: ["passed": passed, "failed": failures.count, "failures": failures], options: [.sortedKeys]), as: UTF8.self))
        return failures.isEmpty ? 0 : 1
    }

    @MainActor static func prepareNormalQuit(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = EditorAppDelegate(recentFiles: RecentLocations(defaults: nil), desktopStore: EditorDesktopStore(directory: directory.appendingPathComponent("support")))
        NSApp.delegate = app
        let file = directory.appendingPathComponent("original.md"), clean = directory.appendingPathComponent("clean.txt")
        try "# Disk original".write(to: file, atomically: true, encoding: .utf8)
        try "Clean tab".write(to: clean, atomically: true, encoding: .utf8)
        let first = app.newWindow(openURLs: [file, clean], projectURL: directory)
        first.selectDocument(0)
        first.setAutoRecovery(true)
        first.currentDocument!.setTextUndoably("# Earlier", actionName: "Fixture")
        first.updateRecoveryForTesting()
        first.currentDocument!.setTextUndoably("# Last edit 中文😀", actionName: "Fixture")
        first.currentTextView!.setSelectedRange(NSRange(location: 2, length: 4))
        let second = app.newWindow()
        _ = second.executeCommand("new_file")
        second.setAutoRecovery(true)
        second.currentDocument!.setTextUndoably("Untitled unfinished note 中文😀", actionName: "Fixture")
        // Real NSApplication.terminate must wait for both final disk writes.
        _ = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: NSApp, queue: .main) { _ in
            let ok = !first.hasRunningWork && !second.hasRunningWork && (try? String(contentsOf: file)) == "# Disk original"
            print("{\"ok\":\(ok),\"passed\":\(ok ? 1 : 0),\"failed\":\(ok ? 0 : 1)}")
            // Keep the delegate alive until the application's termination.
            withExtendedLifetime(app) {}
        }
        func clickKeep(_ view: NSView) -> Bool {
            if let button = view as? NSButton, button.title == "Keep Drafts" { button.performClick(nil); return true }
            return view.subviews.contains(where: clickKeep)
        }
        let timer = Timer(timeInterval: 0.02, repeats: true) { _ in
            MainActor.assumeIsolated {
                if let content = NSApp.modalWindow?.contentView { _ = clickKeep(content) }
            }
        }
        RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
        // AppKit's terminateLater loop cannot drain main dispatch recursively.
        // A timer models a native menu event and permits disk callbacks to run.
        let requestTimer = Timer(timeInterval: 0.1, repeats: false) { _ in MainActor.assumeIsolated { NSApp.terminate(nil) } }
        RunLoop.main.add(requestTimer, forMode: .common)
    }

    @MainActor static func readNormalRestart(directory: URL) async -> Int32 {
        let store = EditorDesktopStore(directory: directory.appendingPathComponent("support"))
        let app = EditorAppDelegate(recentFiles: RecentLocations(defaults: nil), desktopStore: store)
        app.launch(openURLs: [], projectURL: nil)
        let first = app.workspaces.first { $0.documents.contains { $0.storage.string == "# Last edit 中文😀" } }
        let second = app.workspaces.first { $0.currentDocument?.storage.string == "Untitled unfinished note 中文😀" }
        var checks = [app.workspaces.count == 2, first?.documents.count == 2,
            first?.documents.map { $0.fileURL?.lastPathComponent ?? "" } == ["original.md", "clean.txt"],
            first?.currentTextView?.selectedRange() == NSRange(location: 2, length: 4),
            first?.currentDocument?.isModified == true, second?.currentDocument?.isModified == true,
            second?.currentDocument?.fileURL == nil,
            (try? String(contentsOf: directory.appendingPathComponent("original.md"))) == "# Disk original"]
        try? await Task.sleep(nanoseconds: 500_000_000)
        checks.append(RecoveryCandidate.discover(in: app.recoveryDirectory).isEmpty)
        for item in app.workspaces { for document in item.documents { document.checkpoint() }; item.window.performClose(nil) }
        let end = Date().addingTimeInterval(5)
        while !app.workspaces.isEmpty && Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
        checks.append(app.workspaces.isEmpty)
        print(String(decoding: try! JSONSerialization.data(withJSONObject: ["passed": checks.filter { $0 }.count, "failed": checks.filter { !$0 }.count, "checks": checks], options: [.sortedKeys]), as: UTF8.self))
        return checks.allSatisfy { $0 } ? 0 : 1
    }
}
