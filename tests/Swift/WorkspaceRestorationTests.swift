import AppKit

enum WorkspaceRestorationTests {
    @MainActor private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor private static func menuItem(_ title: String, in menu: NSMenu? = nil) -> NSMenuItem? {
        for item in (menu ?? NSApp.mainMenu)?.items ?? [] {
            if item.title == title { return item }
            if let submenu = item.submenu, let found = menuItem(title, in: submenu) { return found }
        }
        return nil
    }
    @MainActor private static func click(_ title: String) -> Bool {
        guard let item = menuItem(title), let action = item.action else { return false }
        return NSApp.sendAction(action, to: item.target, from: item)
    }
    @MainActor private static func configureSidebar(_ workspace: EditorWorkspace, project: URL) throws {
        guard let outline = descendants(workspace.window.contentView!).compactMap({ $0 as? NSOutlineView }).first else {
            throw EditorFailure.invalidEdit("Missing project outline")
        }
        outline.expandItem(outline.item(atRow: 0))
        let nested = project.appendingPathComponent("笔记/中文😀")
        for url in [project.appendingPathComponent("笔记"), nested] {
            guard let row = (0..<outline.numberOfRows).first(where: { workspace.outlineView(outline, viewFor: outline.tableColumns[0], item: outline.item(atRow: $0)!)?.toolTip == url.path }) else {
                throw EditorFailure.invalidEdit("Missing Unicode project folder")
            }
            outline.expandItem(outline.item(atRow: row))
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        for title in ["Toggle Tab Bar", "Toggle Status Bar", "Toggle Line Numbers"] {
            guard click(title) else { throw EditorFailure.invalidEdit("Missing layout action " + title) }
        }
        workspace.window.contentView?.layoutSubtreeIfNeeded()
        if let scroll = outline.enclosingScrollView {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 160))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
    private static func prepareProject(_ directory: URL) throws -> URL {
        let project = directory.appendingPathComponent("project").standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: project.appendingPathComponent("笔记/中文😀"), withIntermediateDirectories: true)
        for index in 0..<60 {
            try "fixture".write(to: project.appendingPathComponent("笔记/中文😀/file-\(index).txt"), atomically: true, encoding: .utf8)
        }
        try "# Disk original".write(to: project.appendingPathComponent("original.md"), atomically: true, encoding: .utf8)
        return project.standardizedFileURL.resolvingSymlinksInPath()
    }
    @MainActor private static func makeApp(_ directory: URL) -> EditorAppDelegate {
        EditorAppDelegate(recentFiles: RecentLocations(defaults: nil), desktopStore: EditorDesktopStore(directory: directory.appendingPathComponent("support")), recentFolders: RecentLocations(defaults: nil, kind: .folders))
    }
    @MainActor static func run(directory: URL) async -> Int32 {
        var passed = 0, failures: [String] = []
        func check(_ name: String, _ value: Bool) { if value { passed += 1 } else { failures.append(name) } }
        do {
            let project = try prepareProject(directory)
            let app = makeApp(directory)
            let first = app.newWindow(projectURL: project)
            try configureSidebar(first, project: project)
            let before = first.desktopSnapshot
            check("Folder-only window has no saved file requirement", before.files.isEmpty && before.sidebar?.selectedPath == "笔记/中文😀")
            let preference = menuItem("Remember Previous Workspace")!
            check("Default native settings menu is checked", app.validateMenuItem(preference) && preference.state == .on)
            first.window.performClose(nil)
            try? await Task.sleep(nanoseconds: 200_000_000)
            check("Closing final window keeps last folder metadata", try app.workspaces.isEmpty && EditorDesktopStore(directory: directory.appendingPathComponent("support")).loadDesktop()?.lastClosedWorkspace?.projectPath == project.path)
            check("Empty-window menu exposes folder and settings actions", menuItem("Reopen Last Folder") != nil && menuItem("Remember Previous Workspace") != nil)
            _ = app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
            let restored = app.activeWorkspace!
            check("Dock reopen restores folder without files", restored.projectFolderURL == project && restored.desktopSnapshot.files.isEmpty)
            check("Dock reopen restores Unicode expansion and selection", restored.desktopSnapshot.sidebar?.expandedFolders == before.sidebar?.expandedFolders && restored.desktopSnapshot.sidebar?.selectedPath == before.sidebar?.selectedPath)
            check("Dock reopen restores hidden chrome", restored.desktopSnapshot.tabsVisible == false && restored.desktopSnapshot.statusVisible == false && restored.desktopSnapshot.lineNumbersVisible == false)
            check("Dock reopen restores actual scrolled sidebar", (before.sidebar?.scrollY ?? 0) > 0 && abs((restored.desktopSnapshot.sidebar?.scrollY ?? 0) - (before.sidebar?.scrollY ?? 0)) < 1)
            if let view = restored.window.contentView, let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: image)
                try image.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("restored-workspace.png"))
            }
            check("Native switch can turn restoration off", click("Remember Previous Workspace") && !app.rememberWorkspace)
            check("Off switch saves canonical preference", try EditorDesktopStore(directory: directory.appendingPathComponent("support")).loadConfiguration()?.rememberWorkspace == false)
            let off = try EditorDesktopStore(directory: directory.appendingPathComponent("support")).loadDesktop()!
            check("Off clears ordinary restore state", off.workspaces.isEmpty && off.lastClosedWorkspace == nil)
            restored.window.performClose(nil)
            _ = app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
            check("Off reopens blank while retaining folder history", app.activeWorkspace?.projectFolderURL == nil && app.recentFolderURLs == [project])
            check("Reopen Last Folder works with switch off", click("Reopen Last Folder") && app.activeWorkspace?.projectFolderURL == project)
            let recent = menuItem("Open Recent Folders")!.submenu!
            app.menuNeedsUpdate(recent)
            check("Recent folder menu carries actual URL", recent.items.contains { $0.representedObject as? URL == project })
            let missing = directory.appendingPathComponent("missing")
            app.openRecentFolder(missing)
            check("Missing folder keeps workspace and reports reason", app.activeWorkspace?.projectFolderURL == project && (app.activeWorkspace?.snapshot["notice"] as? String)?.contains("unavailable") == true)
            check("Native switch can turn restoration back on", click("Remember Previous Workspace") && app.rememberWorkspace)
            let secondProject = directory.appendingPathComponent("other").standardizedFileURL.resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: secondProject, withIntermediateDirectories: true)
            let second = app.newWindow(projectURL: secondProject)
            app.workspaces.first!.window.performClose(nil)
            app.persistDesktop()
            let live = try EditorDesktopStore(directory: directory.appendingPathComponent("support")).loadDesktop()!
            check("Closing one of many windows preserves remaining desktop", live.workspaces.count == 1 && live.workspaces[0].projectPath == secondProject.path && live.lastClosedWorkspace?.projectPath == project.path)
            second.window.performClose(nil)
            _ = app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
            check("Closing all windows reopens last closed folder", app.activeWorkspace?.projectFolderURL?.path == secondProject.path)
            app.activeWorkspace?.window.performClose(nil)
            let fresh = makeApp(directory)
            fresh.launch(openURLs: [project.appendingPathComponent("original.md")], projectURL: nil)
            check("Explicit file launch respects supplied input", fresh.workspaces.count == 1 && fresh.activeWorkspace?.projectFolderURL == nil && fresh.activeWorkspace?.currentDocument?.fileURL == project.appendingPathComponent("original.md"))
            fresh.activeWorkspace?.window.performClose(nil)
            check("Source bytes preserved", try String(contentsOf: project.appendingPathComponent("original.md"), encoding: .utf8) == "# Disk original")
        } catch { failures.append(error.localizedDescription) }
        print(String(decoding: try! JSONSerialization.data(withJSONObject: ["passed": passed, "failed": failures.count, "failures": failures], options: [.sortedKeys]), as: UTF8.self))
        return failures.isEmpty ? 0 : 1
    }

    // Separate OS processes verify normal quit and last-window close. Only
    // temporary fixture dialogs are answered; production windows are untouched.
    @MainActor static func prepareRestart(directory: URL, mode: String) async throws {
        let project = try prepareProject(directory)
        let app = makeApp(directory)
        NSApp.delegate = app
        let workspace = app.newWindow(projectURL: project)
        try configureSidebar(workspace, project: project)
        if mode != "closed" {
            workspace.openDocument(project.appendingPathComponent("original.md"))
            workspace.setAutoRecovery(true)
            workspace.currentDocument!.setTextUndoably("# Last draft 中文😀", actionName: "Fixture")
            try configureSidebarSelection(workspace, project: project)
        }
        if mode == "off" { app.toggleRememberWorkspace() }
        let before = workspace.desktopSnapshot
        try JSONEncoder().encode(before).write(to: directory.appendingPathComponent("expected.json"))
        _ = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: NSApp, queue: .main) { _ in
            print("{\"ok\":true,\"passed\":1,\"failed\":0}")
            withExtendedLifetime(app) {}
        }
        func clickKeep(_ view: NSView) -> Bool {
            if let button = view as? NSButton, button.title == "Keep Drafts" { button.performClick(nil); return true }
            return view.subviews.contains(where: clickKeep)
        }
        let keep = Timer(timeInterval: 0.02, repeats: true) { _ in MainActor.assumeIsolated { if let view = NSApp.modalWindow?.contentView { _ = clickKeep(view) } } }
        RunLoop.main.add(keep, forMode: .common); RunLoop.main.add(keep, forMode: .modalPanel)
        if mode == "closed" {
            workspace.window.performClose(nil)
            guard app.workspaces.isEmpty else { throw EditorFailure.invalidEdit("Last window failed to close") }
        }
        let terminate = Timer(timeInterval: 0.1, repeats: false) { _ in MainActor.assumeIsolated { NSApp.terminate(nil) } }
        RunLoop.main.add(terminate, forMode: .common)
    }
    @MainActor private static func configureSidebarSelection(_ workspace: EditorWorkspace, project: URL) throws {
        // File activation expands its own ancestors. Reapply the folder selection
        // through the same presentation owner before the actual quit snapshot.
        var saved = workspace.desktopSnapshot
        saved.sidebar = .init(expandedFolders: ["", "笔记", "笔记/中文😀"], selectedPath: "笔记/中文😀", scrollY: 160)
        workspace.restoreDesktopPresentation(saved)
    }
    @MainActor static func readRestart(directory: URL, mode: String) async -> Int32 {
        var passed = 0, failures: [String] = []
        func check(_ name: String, _ value: Bool) { if value { passed += 1 } else { failures.append(name) } }
        do {
            let before = try JSONDecoder().decode(SavedWorkspace.self, from: Data(contentsOf: directory.appendingPathComponent("expected.json")))
            let app = makeApp(directory)
            NSApp.delegate = app
            app.launch(openURLs: [], projectURL: nil)
            let workspace = app.activeWorkspace!
            check("One workspace restored", app.workspaces.count == 1)
            check("Switch survives separate process", app.rememberWorkspace == (mode != "off"))
            if mode == "off" {
                check("Off starts blank", workspace.projectFolderURL == nil && workspace.currentDocument?.storage.string.isEmpty == true)
                check("Off preserves manually recoverable draft", RecoveryCandidate.discover(in: app.recoveryDirectory).count == 1)
                check("Off shows draft review action", (workspace.snapshot["notice"] as? String)?.contains("draft backup") == true)
                if let candidate = RecoveryCandidate.discover(in: app.recoveryDirectory).first {
                    _ = try workspace.restoreRecoverySnapshot(candidate.url, into: workspace)
                    check("Off permits manual draft recovery", workspace.currentDocument?.storage.string == "# Last draft 中文😀" && workspace.currentDocument?.isModified == true && !app.rememberWorkspace)
                }
            } else {
                check("Project restored", workspace.projectFolderURL?.path == before.projectPath)
                check("Sidebar survives separate process", workspace.desktopSnapshot.sidebar?.expandedFolders == before.sidebar?.expandedFolders && workspace.desktopSnapshot.sidebar?.selectedPath == before.sidebar?.selectedPath)
                check("Sidebar scroll survives separate process", (before.sidebar?.scrollY ?? 0) > 0 && abs((workspace.desktopSnapshot.sidebar?.scrollY ?? 0) - (before.sidebar?.scrollY ?? 0)) < 1)
                check("Layout survives separate process", workspace.desktopSnapshot.tabsVisible == false && workspace.desktopSnapshot.statusVisible == false && workspace.desktopSnapshot.lineNumbersVisible == false)
                if mode == "closed" { check("Folder-only restart works", workspace.desktopSnapshot.files.isEmpty) }
                else { check("Last draft restored without saving original", workspace.currentDocument?.storage.string == "# Last draft 中文😀" && workspace.currentDocument?.isModified == true) }
            }
            check("Original bytes unchanged", try String(contentsOf: directory.appendingPathComponent("project/original.md"), encoding: .utf8) == "# Disk original")
            try? await Task.sleep(nanoseconds: 500_000_000)
            // Only test fixtures are checkpointed to avoid a second save dialog.
            for document in workspace.documents { document.checkpoint() }
            workspace.window.performClose(nil)
        } catch { failures.append(error.localizedDescription) }
        print(String(decoding: try! JSONSerialization.data(withJSONObject: ["passed": passed, "failed": failures.count, "failures": failures], options: [.sortedKeys]), as: UTF8.self))
        return failures.isEmpty ? 0 : 1
    }
}
