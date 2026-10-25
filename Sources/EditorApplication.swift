import AppKit

/// Owns application lifetime; each workspace owns only its documents and window.
final class EditorAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private(set) var workspaces: [EditorWorkspace] = []
    private let recentFiles: RecentLocations
    private let recentFolders: RecentLocations
    private var desktopState = SavedDesktop(workspaces: [])
    private var configuration: EditorConfiguration?
    private var awaitingTermination = false
    private let desktopStore: EditorDesktopStore?
    private var startupIssue: String?
    private var closingApplication = false
    private(set) var projectInformationWindow: ProjectInformationWindowController?
    var recoveryDirectory: URL { desktopStore?.directory.appendingPathComponent("Recovery") ?? EditorRecovery.defaultDirectory }

    init(recentFiles: RecentLocations = RecentLocations(), desktopStore: EditorDesktopStore? = .production,
         recentFolders: RecentLocations = RecentLocations(defaults: Bundle.main.bundleIdentifier == "org.sourceeditor.SourceEditor" ? .standard : nil, kind: .folders)) {
        self.recentFiles = recentFiles
        self.recentFolders = recentFolders
        self.desktopStore = desktopStore
        super.init()
        NSWindow.allowsAutomaticWindowTabbing = false
        do { configuration = try desktopStore?.loadConfiguration() }
        catch { startupIssue = "Could not load preferences. The original file is preserved: " + error.localizedDescription }
        do { desktopState = try desktopStore?.loadDesktop() ?? SavedDesktop(workspaces: []) }
        catch { startupIssue = "Could not restore workspace. The original file is preserved: " + error.localizedDescription }
    }

    func launch(openURLs: [URL], projectURL: URL?) {
        var restoredRecovery = Set<URL>()
        let restorePrevious = rememberWorkspace && openURLs.isEmpty && projectURL == nil
        if restorePrevious {
            let savedWindows = desktopState.workspaces.isEmpty ? (desktopState.lastClosedWorkspace.map { [$0] } ?? []) : desktopState.workspaces
            for saved in savedWindows {
                let workspace = newWindow()
                workspace.restoreDesktop(saved)
                if let name = saved.recoveryFileName {
                    let url = recoveryDirectory.appendingPathComponent(name).standardizedFileURL
                    if FileManager.default.fileExists(atPath: url.path),
                       (try? EditorSession.load(url))?.closedNormally == true {
                        do {
                            _ = try workspace.restoreRecoverySnapshot(url, into: workspace)
                            restoredRecovery.insert(url)
                        } catch { startupIssue = "Draft backup could not be restored; it is preserved: " + error.localizedDescription }
                    }
                }
            }
        }
        if workspaces.isEmpty { newWindow(openURLs: openURLs, projectURL: projectURL) }
        // Closing a window removes it from the normal desktop list, but its
        // explicitly retained drafts must still return on the next launch.
        for candidate in RecoveryCandidate.discover(in: recoveryDirectory) where restorePrevious && !restoredRecovery.contains(candidate.url.standardizedFileURL) {
            do {
                if try EditorSession.load(candidate.url).closedNormally == true {
                    _ = try activeWorkspace?.restoreRecoverySnapshot(candidate.url)
                }
            } catch { startupIssue = "Draft backup could not be restored; it is preserved: " + error.localizedDescription }
        }
        if let startupIssue { activeWorkspace?.showNotice(startupIssue) }
        if let desktopStore { activeWorkspace?.offerRecoverySnapshots(directory: desktopStore.directory.appendingPathComponent("Recovery")) }
    }

    func persistDesktop() {
        if rememberWorkspace { desktopState.workspaces = workspaces.map(\.desktopSnapshot) }
        else { desktopState = SavedDesktop(workspaces: []) }
        do { try desktopStore?.saveDesktop(desktopState) }
        catch { activeWorkspace?.showNotice("Workspace could not be saved: " + error.localizedDescription) }
    }

    var activeWorkspace: EditorWorkspace? {
        workspaces.first(where: { $0.window === NSApp.keyWindow }) ??
            workspaces.first(where: { $0.window === NSApp.mainWindow }) ?? workspaces.last
    }

    @discardableResult
    func newWindow(openURLs: [URL] = [], projectURL: URL? = nil, tabbed: Bool = true) -> EditorWorkspace {
        let previous = activeWorkspace
        let workspace = EditorWorkspace(recentFiles: recentFiles)
        workspace.applicationOwner = self
        workspaces.append(workspace)
        workspace.start(openURLs: openURLs, projectURL: projectURL, initialConfiguration: configuration)
        if let configuration { workspace.applyLocalConfiguration(configuration, updateDocumentSettings: false) }
        if tabbed, let previous {
            previous.window.addTabbedWindow(workspace.window, ordered: .above)
        }
        workspace.window.makeKeyAndOrderFront(nil)
        workspace.activateMenus()
        workspace.focusContent()
        return workspace
    }

    func mergeWindows() {
        guard let active = activeWorkspace else { return }
        for workspace in workspaces where workspace !== active {
            if active.window.tabbedWindows?.contains(workspace.window) == true { continue }
            workspace.window.deminiaturize(nil)
            active.window.addTabbedWindow(workspace.window, ordered: .above)
        }
        active.window.makeKeyAndOrderFront(nil)
    }

    func windowClosed(_ workspace: EditorWorkspace) {
        if !closingApplication, rememberWorkspace { desktopState.lastClosedWorkspace = workspace.desktopSnapshot }
        workspaces.removeAll(where: { $0 === workspace })
        if !closingApplication { persistDesktop() }
        if let active = activeWorkspace { active.activateMenus() }
        else { installEmptyWindowMenus() }
    }

    @objc func newWindowForTab(_ sender: Any?) { newWindow() }

    var recentFolderURLs: [URL] { recentFolders.urls }
    func noteRecentFolder(_ url: URL) { recentFolders.note(url); refreshHomes() }
    func refreshHomes() { for workspace in workspaces { workspace.refreshHome() } }
    func relocateRecentFolders(from source: URL, to destination: URL) { recentFolders.relocate(from: source, to: destination) }
    func openRecentFolder(_ url: URL) {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            if let activeWorkspace { activeWorkspace.showNotice("Recent folder is unavailable: " + url.path) }
            else { let alert = NSAlert(); alert.messageText = "Recent folder is unavailable"; alert.informativeText = url.path; alert.runModal() }
            return
        }
        if let owner = workspaces.first(where: { $0.projectFolderURL == url }) {
            owner.window.makeKeyAndOrderFront(nil)
        } else if let activeWorkspace { activeWorkspace.setProject(url) }
        else { newWindow(projectURL: url) }
    }
    @objc func reopenLastFolder() { if let url = recentFolders.urls.first { openRecentFolder(url) } }
    @objc private func openRecentFolderMenuItem(_ sender: NSMenuItem) { if let url = sender.representedObject as? URL { openRecentFolder(url) } }
    @objc private func clearRecentFolders() { recentFolders.clear(); refreshHomes() }
    func addFolderMenuItems(to menu: NSMenu) {
        let last = NSMenuItem(title: "Reopen Last Folder", action: #selector(reopenLastFolder), keyEquivalent: "")
        last.target = self; menu.addItem(last)
        let recent = NSMenu(title: "Open Recent Folders")
        recent.delegate = self
        let item = NSMenuItem(title: recent.title, action: nil, keyEquivalent: "")
        item.submenu = recent; menu.addItem(item)
        menuNeedsUpdate(recent)
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.autoenablesItems = false
        menu.removeAllItems()
        if recentFolders.urls.isEmpty {
            let empty = NSMenuItem(title: "No Recent Folders", action: nil, keyEquivalent: "")
            empty.isEnabled = false; menu.addItem(empty)
        }
        for url in recentFolders.urls {
            let item = NSMenuItem(title: url.lastPathComponent + "  (" + url.deletingLastPathComponent().lastPathComponent + ")", action: #selector(openRecentFolderMenuItem(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = url; item.toolTip = url.path; menu.addItem(item)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear Recent Folders", action: #selector(clearRecentFolders), keyEquivalent: "")
        clear.target = self; clear.isEnabled = !recentFolders.urls.isEmpty; menu.addItem(clear)
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleRememberWorkspace) { menuItem.state = rememberWorkspace ? .on : .off }
        return menuItem.action != #selector(reopenLastFolder) || !recentFolders.urls.isEmpty
    }
    var rememberWorkspace: Bool { configuration?.rememberWorkspace ?? true }
    @objc func toggleRememberWorkspace() {
        var config = configuration ?? EditorConfiguration()
        config.rememberWorkspace.toggle()
        applyConfiguration(config, updateDocumentSettings: false)
    }
    func addWorkspacePreferenceItem(to menu: NSMenu) {
        let item = NSMenuItem(title: "Remember Previous Workspace", action: #selector(toggleRememberWorkspace), keyEquivalent: "")
        item.target = self; menu.addItem(item)
    }

    func addProjectInformationMenuItems(to menu: NSMenu) {
        for (title, action) in [("About Source Editor", #selector(showProjectInformation)),
                                ("Release Notes…", #selector(showReleaseNotes)),
                                ("Contact Author…", #selector(contactAuthor))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
    }

    private func informationController() -> ProjectInformationWindowController? {
        if let projectInformationWindow { return projectInformationWindow }
        do {
            let controller = ProjectInformationWindowController(information: try ProjectInformation.load())
            projectInformationWindow = controller
            return controller
        } catch {
            activeWorkspace?.showNotice("Could not load project information: " + error.localizedDescription)
            return nil
        }
    }
    @objc func showProjectInformation() { informationController()?.show(.about) }
    @objc func showReleaseNotes() { informationController()?.show(.releases) }
    @objc func contactAuthor() {
        if let url = informationController()?.information.contactURL { NSWorkspace.shared.open(url) }
    }

    private func installEmptyWindowMenus() {
        let main = NSMenu()
        let app = NSMenu(title: "Source Editor")
        addProjectInformationMenuItems(to: app)
        app.addItem(.separator())
        app.addItem(NSMenuItem(title: "Quit Source Editor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let file = NSMenu(title: "File")
        let new = NSMenuItem(title: "New Window", action: #selector(newWindowForTab(_:)), keyEquivalent: "N")
        new.keyEquivalentModifierMask = [.command, .shift]
        new.target = self
        file.addItem(new)
        addFolderMenuItems(to: file)
        let preferences = NSMenu(title: "Preferences")
        addWorkspacePreferenceItem(to: preferences)
        for menu in [app, file, preferences] {
            let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
        }
        NSApp.windowsMenu = nil
        NSApp.mainMenu = main
    }

    func applyConfiguration(_ value: EditorConfiguration, updateDocumentSettings: Bool) {
        let rememberChanged = rememberWorkspace != value.rememberWorkspace
        configuration = value
        for workspace in workspaces { workspace.applyLocalConfiguration(value, updateDocumentSettings: updateDocumentSettings) }
        activeWorkspace?.activateMenus()
        do { try desktopStore?.saveConfiguration(value) }
        catch { activeWorkspace?.showNotice("Preferences could not be saved: " + error.localizedDescription) }
        if rememberChanged { persistDesktop() }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if workspaces.isEmpty { newWindow() }
        for filename in filenames {
            let url = URL(fileURLWithPath: filename).standardizedFileURL.resolvingSymlinksInPath()
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue {
                activeWorkspace?.setProject(url)
            } else {
                let owner = workspaces.first(where: { workspace in workspace.documents.contains(where: { $0.fileURL == url }) }) ?? activeWorkspace
                owner?.window.makeKeyAndOrderFront(nil)
                owner?.openDocument(url)
            }
        }
        activeWorkspace?.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if workspaces.isEmpty { launch(openURLs: [], projectURL: nil) }
        else if let active = activeWorkspace {
            active.window.deminiaturize(nil)
            active.window.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if awaitingTermination { return .terminateLater }
        // Ask about every window before cancelling work or freezing any editor.
        for workspace in workspaces {
            if !workspace.confirmDocumentsBeforeClosing() { return .terminateCancel }
        }
        persistDesktop()
        closingApplication = true
        let busy = workspaces.contains(where: { $0.hasRunningWork })
        awaitingTermination = busy
        for workspace in workspaces { workspace.prepareForApplicationTermination() }
        return busy ? .terminateLater : .terminateNow
    }

    func workspaceFinishedWork() {
        guard awaitingTermination, !workspaces.contains(where: { $0.hasRunningWork }) else { return }
        awaitingTermination = false
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    func cancelTerminationAfterRecoveryFailure() {
        guard closingApplication else { return }
        closingApplication = false
        let wasAwaiting = awaitingTermination
        awaitingTermination = false
        for workspace in workspaces { workspace.cancelPendingClose() }
        if wasAwaiting { NSApp.reply(toApplicationShouldTerminate: false) }
    }
}

/// Direct CLI launches use LaunchServices to deliver files to the running app.
/// Normal Finder/open launches are already reused by LaunchServices.
func forwardToRunningEditor(openURLs: [URL], projectURL: URL?) -> Bool {
    guard let identifier = Bundle.main.bundleIdentifier,
          Bundle.main.bundleURL.pathExtension == "app",
          let running = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }),
          let bundleURL = running.bundleURL else { return false }
    let config = NSWorkspace.OpenConfiguration()
    config.createsNewApplicationInstance = false
    config.activates = true
    let urls = (projectURL.map { [$0] } ?? []) + openURLs
    var finished = false
    var failure: Error?
    let completion: (NSRunningApplication?, Error?) -> Void = { _, error in
        DispatchQueue.main.async { failure = error; finished = true }
    }
    if urls.isEmpty { NSWorkspace.shared.openApplication(at: bundleURL, configuration: config, completionHandler: completion) }
    else { NSWorkspace.shared.open(urls, withApplicationAt: bundleURL, configuration: config, completionHandler: completion) }
    let deadline = Date().addingTimeInterval(10)
    while !finished && Date() < deadline { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
    if !finished || failure != nil {
        fputs("Could not open the running Source Editor: \(failure?.localizedDescription ?? "LaunchServices timed out")\n", stderr)
        exit(1)
    }
    return true
}
