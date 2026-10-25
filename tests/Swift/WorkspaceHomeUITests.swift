import AppKit

private final class HomeFileChooser: EditorFileChoosing {
    var urls: [URL]?
    var requests = 0
    func choose(_ panel: NSSavePanel, for parent: NSWindow) -> [URL]? { requests += 1; return urls }
}

enum WorkspaceHomeUITests {
    @MainActor static func run(directory: URL) async -> Int32 {
        var passed = 0, failures: [String] = []
        func check(_ name: String, _ value: Bool) { if value { passed += 1 } else { failures.append(name) } }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func controls(_ workspace: EditorWorkspace) -> [NSView] {
            descendants(workspace.window.contentView!) + workspace.window.titlebarAccessoryViewControllers.flatMap { descendants($0.view) }
        }
        func button(_ id: String, in workspace: EditorWorkspace) -> NSButton? { controls(workspace).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == id } }
        func click(_ id: String, in workspace: EditorWorkspace) -> Bool {
            guard let value = button(id, in: workspace), value.isEnabled else { return false }
            value.performClick(nil); return true
        }
        func menuAction(_ title: String, workspace: EditorWorkspace) -> Bool {
            workspace.activateMenus()
            func item(_ menu: NSMenu) -> NSMenuItem? {
                for entry in menu.items {
                    if entry.title == title { return entry }
                    if let submenu = entry.submenu, let found = item(submenu) { return found }
                }
                return nil
            }
            guard let entry = item(NSApp.mainMenu!), let action = entry.action else { return false }
            return NSApp.sendAction(action, to: entry.target, from: entry)
        }
        func pump() async { try? await Task.sleep(nanoseconds: 150_000_000) }
        func capture(_ workspace: EditorWorkspace, name: String) throws {
            let view = workspace.window.contentView!
            view.layoutSubtreeIfNeeded()
            guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: image)
            try image.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name))
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let project = directory.appendingPathComponent("Project 中文😀")
            let other = directory.appendingPathComponent("Other Project")
            for folder in [project, other] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            let file = project.appendingPathComponent("daily.md")
            try "# Original 中文😀\n".write(to: file, atomically: true, encoding: .utf8)
            let original = try Data(contentsOf: file)
            let app = EditorAppDelegate(recentFiles: RecentLocations(defaults: nil), desktopStore: EditorDesktopStore(directory: directory.appendingPathComponent("support")), recentFolders: RecentLocations(defaults: nil, kind: .folders))
            let direct = app.newWindow(projectURL: project, tabbed: false)
            check("Folder launch starts native home without an untitled document", direct.documents.isEmpty && direct.currentTextView == nil && direct.snapshot["homeVisible"] as? Bool == true)
            check("Home has no Markdown renderer", direct.markdownPreviewForTesting == nil)
            direct.window.performClose(nil)
            let workspace = app.newWindow(tabbed: false)
            workspace.window.setContentSize(NSSize(width: 1220, height: 810))
            let originalFrame = workspace.window.frame
            let chooser = HomeFileChooser(); workspace.fileChooser = chooser
            check("New window starts on welcome home", workspace.documents.isEmpty && workspace.snapshot["homeVisible"] as? Bool == true)
            check("No project disables project-only quick actions", button("home.quickOpen", in: workspace)?.isEnabled == false && button("home.findProject", in: workspace)?.isEnabled == false)
            chooser.urls = [project]
            check("Home Open Folder reaches chooser", click("home.openFolder", in: workspace) && chooser.requests == 1)
            check("Folder chooser keeps home and project", workspace.projectFolderURL?.path == project.path && workspace.documents.isEmpty && workspace.snapshot["homeVisible"] as? Bool == true)
            check("Project actions become enabled", button("home.quickOpen", in: workspace)?.isEnabled == true && button("home.findProject", in: workspace)?.isEnabled == true)
            await pump()
            check("Home Quick Open reaches command palette", click("home.quickOpen", in: workspace) && workspace.snapshot["paletteVisible"] as? Bool == true)
            _ = workspace.executeCommand("dismiss_palette")
            _ = click("home.findProject", in: workspace)
            let searchPanel = NSApp.windows.first { $0.isVisible && $0.title.hasPrefix("Find in Project — ") }
            check("Home Find in Folder opens the actual project search panel", searchPanel != nil)
            if let view = searchPanel?.contentView { descendants(view).compactMap { $0 as? NSButton }.first { $0.title == "Close" }?.performClick(nil) }
            workspace.window.makeKeyAndOrderFront(nil)
            check("Home New File creates one actual buffer", click("home.newFile", in: workspace) && workspace.documents.count == 1 && workspace.currentDocument?.storage.string.isEmpty == true && workspace.snapshot["homeVisible"] as? Bool == false)
            check("New file receives editing focus", workspace.window.firstResponder === workspace.currentTextView)
            _ = workspace.executeCommand("close_tab")
            check("Closing last tab returns home without replacement buffer", workspace.documents.isEmpty && workspace.currentTextView == nil && workspace.snapshot["homeVisible"] as? Bool == true)
            let saveItem = NSApp.mainMenu!.item(withTitle: "File")!.submenu!.item(withTitle: "Save")!
            check("Home disables Save and avoids a save chooser", !workspace.validateMenuItem(saveItem))
            let requests = chooser.requests
            _ = workspace.executeCommand("save_session")
            check("Empty home does not write an invalid session", chooser.requests == requests)
            check("Home Markdown action creates a Markdown buffer", click("home.newNote", in: workspace) && workspace.currentDocument?.syntaxIdentifier == "md" && workspace.currentTextView != nil)
            workspace.currentDocument?.checkpoint(); _ = workspace.executeCommand("close_tab")
            chooser.urls = [file]
            check("Home Open File opens real source", click("home.openFile", in: workspace) && workspace.currentDocument?.fileURL?.path == file.path && workspace.snapshot["homeVisible"] as? Bool == false)
            check("Document encoding controls appear only in editing", button("status.encoding", in: workspace)?.isHiddenOrHasHiddenAncestor == false)
            workspace.currentTextView?.setSelectedRange(NSRange(location: 2, length: 3))
            workspace.window.contentView?.layoutSubtreeIfNeeded()
            let editingWidth = workspace.snapshot["editorAreaWidth"] as! CGFloat
            _ = click("workspace.toggleSidebar", in: workspace)
            workspace.window.contentView?.layoutSubtreeIfNeeded()
            check("Sidebar button enlarges editor without changing file or selection", (workspace.snapshot["editorAreaWidth"] as! CGFloat) > editingWidth + 100 && workspace.currentDocument?.fileURL?.path == file.path && workspace.currentTextView?.selectedRange() == NSRange(location: 2, length: 3))
            _ = click("workspace.toggleSidebar", in: workspace)
            _ = workspace.executeCommand("close_tab")
            check("Document encoding controls are hidden on home", button("status.encoding", in: workspace)?.isHidden == true)
            check("Recent file button reopens source", click("home.file.0", in: workspace) && workspace.currentDocument?.fileURL?.path == file.path && workspace.documents.count == 1)
            _ = workspace.executeCommand("close_tab")
            chooser.urls = [other]
            _ = click("home.openFolder", in: workspace)
            check("Recent folder button changes current project", click("home.folder.1", in: workspace) && workspace.projectFolderURL?.path == project.path && workspace.documents.isEmpty)
            workspace.window.contentView?.layoutSubtreeIfNeeded()
            let width = workspace.snapshot["editorAreaWidth"] as! CGFloat
            check("Sidebar header has a visible collapse button", button("sidebar.hide", in: workspace)?.isHiddenOrHasHiddenAncestor == false)
            check("Sidebar header collapses directory", click("sidebar.hide", in: workspace) && workspace.snapshot["sidebarVisible"] as? Bool == false)
            workspace.window.contentView?.layoutSubtreeIfNeeded()
            check("Home grows when sidebar is hidden", (workspace.snapshot["editorAreaWidth"] as! CGFloat) > width + 100)
            check("Titlebar keeps a restore button while sidebar is hidden", button("workspace.toggleSidebar", in: workspace)?.accessibilityLabel() == "Show Sidebar")
            check("Titlebar button restores directory", click("workspace.toggleSidebar", in: workspace) && workspace.snapshot["sidebarVisible"] as? Bool == true)
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .control], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: workspace.window.windowNumber, context: nil, characters: "b", charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11) {
                check("Existing sidebar shortcut uses the same window action", NSApp.mainMenu?.performKeyEquivalent(with: event) == true && workspace.snapshot["sidebarVisible"] as? Bool == false)
                _ = click("workspace.toggleSidebar", in: workspace)
            }
            _ = menuAction("Toggle Tab Bar", workspace: workspace)
            _ = menuAction("Toggle Status Bar", workspace: workspace)
            check("Sidebar button works with editor chrome hidden", click("workspace.toggleSidebar", in: workspace) && workspace.snapshot["sidebarVisible"] as? Bool == false)
            _ = click("workspace.toggleSidebar", in: workspace)
            try capture(workspace, name: "home-dark.png")
            _ = menuAction("Light", workspace: workspace)
            check("Home responds to light theme", workspace.snapshot["theme"] as? String == "light")
            try capture(workspace, name: "home-light.png")
            workspace.window.setContentSize(NSSize(width: 760, height: 420))
            workspace.window.contentView?.layoutSubtreeIfNeeded()
            let home = controls(workspace).compactMap { $0 as? WorkspaceHomeView }.first!
            home.layoutSubtreeIfNeeded()
            check("Narrow home stacks actions and scrolls vertically", home.hasVerticalScroller && !home.hasHorizontalScroller && (home.documentView?.bounds.height ?? 0) > home.contentSize.height && button("home.newFile", in: workspace)?.frame.minX == button("home.openFile", in: workspace)?.frame.minX)
            check("Narrow quick actions stay inside the home viewport", ["home.newFile", "home.openFile", "home.openFolder", "home.newNote", "home.quickOpen", "home.findProject"].allSatisfy { id in
                guard let control = button(id, in: workspace) else { return false }
                return control.frame.minX >= 0 && control.frame.maxX <= home.contentSize.width
            })
            try capture(workspace, name: "home-narrow.png")
            // Do not leave the narrow probe in shared native frame autosave.
            workspace.window.setFrame(originalFrame, display: true)
            check("Home operations preserve original bytes", try Data(contentsOf: file) == original)
            app.persistDesktop()
            workspace.window.performClose(nil)
            let reopened = EditorAppDelegate(recentFiles: RecentLocations(defaults: nil), desktopStore: EditorDesktopStore(directory: directory.appendingPathComponent("support")))
            reopened.launch(openURLs: [], projectURL: nil)
            check("Folder-only restart restores home and project", reopened.workspaces.count == 1 && reopened.activeWorkspace?.projectFolderURL?.path == project.path && reopened.activeWorkspace?.documents.isEmpty == true && reopened.activeWorkspace?.snapshot["homeVisible"] as? Bool == true)
            reopened.activeWorkspace?.window.performClose(nil)
        } catch { failures.append(error.localizedDescription) }
        print(String(decoding: try! JSONSerialization.data(withJSONObject: ["passed": passed, "failed": failures.count, "failures": failures, "scope": "native AppKit home, buttons, menu actions, resizing and injected file chooser; original bytes preserved"], options: [.sortedKeys]), as: UTF8.self))
        return failures.isEmpty ? 0 : 1
    }
}
