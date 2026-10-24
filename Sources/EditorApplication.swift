import AppKit

/// Owns application lifetime; each workspace owns only its documents and window.
final class EditorAppDelegate: NSObject, NSApplicationDelegate {
    private(set) var workspaces: [EditorWorkspace] = []
    private let recentFiles: RecentFiles
    private var configuration: EditorConfiguration?
    private var awaitingTermination = false
    private let desktopStore: EditorDesktopStore?
    private var startupIssue: String?
    private var closingApplication = false
    var recoveryDirectory: URL { desktopStore?.directory.appendingPathComponent("Recovery") ?? EditorRecovery.defaultDirectory }

    init(recentFiles: RecentFiles = RecentFiles(), desktopStore: EditorDesktopStore? = .production) {
        self.recentFiles = recentFiles
        self.desktopStore = desktopStore
        super.init()
        NSWindow.allowsAutomaticWindowTabbing = false
        do { configuration = try desktopStore?.loadConfiguration() }
        catch { startupIssue = "Could not load preferences. The original file is preserved: " + error.localizedDescription }
    }

    func launch(openURLs: [URL], projectURL: URL?) {
        var restoredRecovery = Set<URL>()
        if openURLs.isEmpty, projectURL == nil {
            do {
                if let state = try desktopStore?.loadDesktop() {
                    for saved in state.workspaces {
                        let workspace = newWindow()
                        workspace.restoreDesktop(saved)
                        if let name = saved.recoveryFileName {
                            let url = recoveryDirectory.appendingPathComponent(name).standardizedFileURL
                            if FileManager.default.fileExists(atPath: url.path),
                               (try? EditorSession.load(url))?.closedNormally == true {
                                _ = try workspace.restoreRecoverySnapshot(url, into: workspace)
                                restoredRecovery.insert(url)
                            }
                        }
                    }
                }
            } catch { startupIssue = "Could not restore workspace. The original file is preserved: " + error.localizedDescription }
        }
        if workspaces.isEmpty { newWindow(openURLs: openURLs, projectURL: projectURL) }
        // Closing a window removes it from the normal desktop list, but its
        // explicitly retained drafts must still return on the next launch.
        for candidate in RecoveryCandidate.discover(in: recoveryDirectory) where !restoredRecovery.contains(candidate.url.standardizedFileURL) {
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
        do { try desktopStore?.saveDesktop(SavedDesktop(workspaces: workspaces.map(\.desktopSnapshot))) }
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
        workspace.window.makeFirstResponder(workspace.currentTextView)
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
        workspaces.removeAll(where: { $0 === workspace })
        if !closingApplication { persistDesktop() }
        if let active = activeWorkspace { active.activateMenus() }
        else { installEmptyWindowMenus() }
    }

    @objc func newWindowForTab(_ sender: Any?) { newWindow() }

    private func installEmptyWindowMenus() {
        let main = NSMenu()
        let app = NSMenu(title: "Source Editor")
        app.addItem(NSMenuItem(title: "Quit Source Editor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let file = NSMenu(title: "File")
        let new = NSMenuItem(title: "New Window", action: #selector(newWindowForTab(_:)), keyEquivalent: "N")
        new.keyEquivalentModifierMask = [.command, .shift]
        new.target = self
        file.addItem(new)
        for menu in [app, file] {
            let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
        }
        NSApp.windowsMenu = nil
        NSApp.mainMenu = main
    }

    func applyConfiguration(_ value: EditorConfiguration, updateDocumentSettings: Bool) {
        configuration = value
        for workspace in workspaces { workspace.applyLocalConfiguration(value, updateDocumentSettings: updateDocumentSettings) }
        activeWorkspace?.activateMenus()
        do { try desktopStore?.saveConfiguration(value) }
        catch { activeWorkspace?.showNotice("Preferences could not be saved: " + error.localizedDescription) }
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
