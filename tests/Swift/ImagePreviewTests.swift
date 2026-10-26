import AppKit
import ImageIO

enum ImagePreviewTests {
    static func fixture(_ url: URL, width: Int = 320, height: Int = 180, type: CFString = "public.png" as CFString, frames: Int = 1, orientation: Int? = nil) throws {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw EditorFailure.invalidEdit("Fixture allocation failed") }
        context.setFillColor(CGColor(red: 0.15, green: 0.45, blue: 0.85, alpha: 0.7)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 0.25, blue: 0.2, alpha: 1)); context.fill(CGRect(x: 10, y: 10, width: width / 3, height: height / 3))
        guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithURL(url as CFURL, type, frames, nil) else { throw EditorFailure.invalidEdit("Fixture encoder unavailable") }
        let properties: CFDictionary? = orientation.map { [kCGImagePropertyOrientation: $0] as CFDictionary }
        for _ in 0..<frames { CGImageDestinationAddImage(destination, image, properties) }
        guard CGImageDestinationFinalize(destination) else { throw EditorFailure.invalidEdit("Fixture encoding failed") }
    }
    @MainActor static func run(directory: URL) async -> Int32 {
        var passed = 0, failures: [String] = []
        func check(_ name: String, _ value: Bool) { if value { passed += 1 } else { failures.append(name); print("FAIL: " + name) } }
        func rejects(_ name: String, _ action: () throws -> Void) { do { try action(); check(name, false) } catch { check(name, true) } }
        func pump() async { try? await Task.sleep(nanoseconds: 100_000_000) }
        func wait(_ condition: () -> Bool) async -> Bool {
            for _ in 0..<80 { if condition() { return true }; await pump() }; return condition()
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func previews(_ workspace: EditorWorkspace) -> [ImagePreviewView] { descendants(workspace.window.contentView!).compactMap { $0 as? ImagePreviewView } }
        func button(_ id: String, _ preview: ImagePreviewView) -> NSButton { descendants(preview).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == id }! }
        func menu(_ title: String, _ workspace: EditorWorkspace) -> NSMenuItem? {
            workspace.activateMenus()
            func find(_ menu: NSMenu) -> NSMenuItem? { for item in menu.items { if item.title == title { return item }; if let submenu = item.submenu, let item = find(submenu) { return item } }; return nil }
            return find(NSApp.mainMenu!)
        }
        func capture(_ workspace: EditorWorkspace, _ name: String) throws {
            if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(workspace.window.windowNumber), .boundsIgnoreFraming) {
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name))
            }
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let png = directory.appendingPathComponent("Image 中文😀.PNG")
            try fixture(png, width: 4096, height: 2048)
            let original = try Data(contentsOf: png)
            let document = try EditorDocument.open(png)
            check("Image opens as metadata without binary text", !document.isTextDocument && document.storage.length == 0 && document.imageAsset?.width == 4096 && document.fileURL == png)
            check("Image never becomes a dirty text document", !document.isModified && document.diskDigestHex == nil)
            rejects("Image cannot be saved over the original", { try document.save() })
            rejects("Image Save As cannot create an empty text file", { try document.save(to: directory.appendingPathComponent("copy.png")) })
            rejects("Image encoding mutation is rejected", { try document.setEncoding(.utf8) })
            rejects("Image indentation mutation is rejected", { try document.updateSettings(DocumentSettings()) })
            document.setTextUndoably("attempt", actionName: "Fixture")
            check("Programmatic text edits cannot mutate images", document.storage.length == 0 && !document.isModified && !document.undoManager.canUndo)
            let thumbnail = try document.imageAsset!.thumbnail()
            check("Retained decode is bounded to the configured edge", thumbnail.width == 2048 && thumbnail.height == 1024)
            check("Rejected operations leave source bytes unchanged", (try? Data(contentsOf: png)) == original && !FileManager.default.fileExists(atPath: directory.appendingPathComponent("copy.png").path))
            let broken = directory.appendingPathComponent("broken.png"); try "not an image".write(to: broken, atomically: true, encoding: .utf8)
            rejects("Corrupt image does not fall back to text", { _ = try EditorDocument.open(broken) })
            let oversized = directory.appendingPathComponent("oversized.png")
            try original.write(to: oversized)
            let oversizedFile = try FileHandle(forWritingTo: oversized)
            try oversizedFile.truncate(atOffset: UInt64(EditorImageAsset.maximumFileBytes + 1)); try oversizedFile.close()
            rejects("Oversized image is rejected before reading binary contents", { _ = try EditorDocument.open(oversized) })
            try FileManager.default.removeItem(at: oversized)
            let animation = directory.appendingPathComponent("animated.gif"); try fixture(animation, type: "com.compuserve.gif" as CFString, frames: 2)
            check("GIF metadata identifies the static first-frame scope", try EditorDocument.open(animation).imageAsset?.frames == 2)
            let jpeg = directory.appendingPathComponent("orientation.jpg"); try fixture(jpeg, type: "public.jpeg" as CFString, orientation: 6)
            let rotated = try EditorDocument.open(jpeg).imageAsset!
            let rotatedPreview = try rotated.thumbnail()
            check("EXIF orientation controls dimensions and decode", rotated.width == 180 && rotated.height == 320 && rotatedPreview.width == 180)
            let tiff = directory.appendingPathComponent("sample.tiff"); try fixture(tiff, type: "public.tiff" as CFString)
            check("TIFF uses the image path", try !EditorDocument.open(tiff).isTextDocument)
            let bmp = directory.appendingPathComponent("sample.bmp"); try fixture(bmp, type: "com.microsoft.bmp" as CFString)
            check("BMP uses the image path", try !EditorDocument.open(bmp).isTextDocument)
            let renamed = directory.appendingPathComponent("renamed.txt")
            try original.write(to: renamed)
            document.relocate(to: renamed)
            let entry = EditorSession.Document(document: document, ranges: [])
            let encoded = try JSONEncoder().encode(entry)
            let restored = try JSONDecoder().decode(EditorSession.Document.self, from: encoded).restore().0
            check("Session stores image references, including renamed extensions", encoded.count < 2048 && !restored.isTextDocument && restored.fileURL == renamed && restored.storage.length == 0)
            try FileManager.default.removeItem(at: renamed)
            rejects("Missing image session fails without creating an empty text buffer", { _ = try entry.restore() })
            let notes = directory.appendingPathComponent("notes.txt"); try "Keep this text\n".write(to: notes, atomically: true, encoding: .utf8)
            let app = EditorAppDelegate(recentFiles: RecentLocations(defaults: nil), desktopStore: EditorDesktopStore(directory: directory.appendingPathComponent("support")), recentFolders: RecentLocations(defaults: nil, kind: .folders))
            let workspace = app.newWindow(tabbed: false)
            workspace.window.setContentSize(NSSize(width: 1220, height: 810))
            workspace.setProject(directory)
            check("Native open selects an image tab and exposes no editable text view", workspace.openDocument(png) && workspace.currentTextView == nil && workspace.currentDocument?.fileURL == png)
            guard let preview = previews(workspace).first else { throw EditorFailure.invalidEdit("Image pane missing") }
            check("Background native decode completes", await wait { !preview.loading && preview.decodedPixelSize.width == 2048 })
            workspace.window.contentView?.layoutSubtreeIfNeeded(); await pump()
            check("Initial fit is visible inside the native viewport", preview.scale > 0 && preview.scale < 1 && preview.visibleRect.width > 500 && workspace.window.firstResponder === preview)
            let encodingButtons = descendants(workspace.window.contentView!).filter { $0.identifier?.rawValue == "status.encoding" }
            check("Encoding controls are hidden for images", encodingButtons.count == 1 && encodingButtons[0].isHidden)
            check("Text Save and Find menus are disabled", menu("Save", workspace).map { !workspace.validateMenuItem($0) } == true && menu("Find…", workspace).map { !workspace.validateMenuItem($0) } == true)
            check("Image menu targets the active pane", menu("Actual Image Size", workspace).map { workspace.validateMenuItem($0) } == true)
            button("image.actual", preview).performClick(nil)
            check("Actual-size button uses source-pixel geometry", preview.scale == 1)
            button("image.zoomIn", preview).performClick(nil); check("Zoom-in button changes scale", preview.scale == 1.25)
            button("image.zoomOut", preview).performClick(nil); check("Zoom-out button changes scale", preview.scale == 1)
            _ = workspace.executeCommand("image_fit"); workspace.window.contentView?.layoutSubtreeIfNeeded()
            check("Fit command returns to a bounded viewport", preview.scale < 1)
            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: workspace.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            let context = preview.menu(for: event)!
            check("Image context contains path, Finder, zoom and reload actions", context.item(withTitle: "Copy File Path") != nil && context.item(withTitle: "Open Containing Folder…") != nil && context.item(withTitle: "Fit Image") != nil && context.item(withTitle: "Reload Image") != nil)
            check("Image context Save As is disabled", context.item(withTitle: "Save As…")?.isEnabled == false)
            await pump(); try capture(workspace, "image-dark.png")
            _ = workspace.executeCommand("split_right"); _ = workspace.executeCommand("focus_next_pane")
            check("Images can appear in both split panes", previews(workspace).count == 2)
            check("Text opens alongside the image", workspace.openDocument(notes) && previews(workspace).count == 1 && workspace.currentTextView?.string == "Keep this text\n")
            let companion = previews(workspace).first!
            workspace.window.makeFirstResponder(companion)
            check("Image focus routes title and active file correctly", workspace.currentDocument?.fileURL == png && workspace.currentTextView == nil && workspace.window.title.contains(png.lastPathComponent))
            let otherText = workspace.paneViewsForTesting.last!
            button("image.actual", companion).performClick(nil)
            check("Image zoom preserves companion text", otherText.string == "Keep this text\n")
            workspace.startFileMonitoring()
            try fixture(png, width: 400, height: 240)
            check("Real file events reload images without a text decode", await wait { workspace.currentDocument?.imageAsset?.width == 400 && !companion.loading && companion.decodedPixelSize.width == 400 })
            let saved = workspace.desktopSnapshot
            let reopened = app.newWindow(tabbed: false); reopened.restoreDesktop(saved)
            check("Desktop restores image, text and split focus", reopened.currentDocument?.fileURL == png && reopened.currentTextView == nil && previews(reopened).count == 1 && reopened.documents.count == 2)
            let imageSession = EditorSession(projectPath: directory.path, selectedIndex: 0, split: false, documents: [EditorSession.Document(document: workspace.currentDocument!, ranges: [])])
            let sessionURL = directory.appendingPathComponent("images.session"); try imageSession.save(sessionURL)
            check("Explicit session restores a native image tab", reopened.restoreSession(try EditorSession.load(sessionURL)) && previews(reopened).count == 1 && reopened.currentTextView == nil)
            check("Repeated image open reuses the tab", reopened.openDocument(png) && reopened.documents.count == 1)
            var configuration = EditorConfiguration(); configuration.theme = "light"; configuration.tabSize = 2
            reopened.applyConfiguration(configuration)
            check("Text preferences and themes skip read-only image settings", reopened.currentDocument?.imageAsset != nil && reopened.currentDocument?.settings.tabSize == 4 && workspace.documents.first(where: { $0.isTextDocument })?.settings.tabSize == 2)
            reopened.window.setContentSize(NSSize(width: 760, height: 420)); reopened.window.contentView?.layoutSubtreeIfNeeded()
            check("Narrow light preview remains visible", previews(reopened).first!.visibleRect.width > 200)
            await pump(); try capture(reopened, "image-light-narrow.png")
            weak var released: ImagePreviewView?
            do { let ephemeral = previews(reopened).first!; released = ephemeral }
            _ = reopened.executeCommand("close_tab")
            check("Closing an image restores home", reopened.documents.isEmpty && previews(reopened).isEmpty && reopened.currentDocument == nil)
            check("Closed image view and decode are released", await wait { released == nil })
            for _ in 0..<16 { _ = reopened.openDocument(png); _ = reopened.executeCommand("close_tab") }
            check("Rapid open-close cycles leave no image panes or documents", previews(reopened).isEmpty && reopened.documents.isEmpty)
            check("Image preview commands do not create drafts", workspace.documents.allSatisfy { !$0.isModified } && reopened.documents.isEmpty)
            reopened.window.performClose(nil); workspace.window.performClose(nil)
        } catch { failures.append(error.localizedDescription) }
        let result: [String: Any] = ["passed": passed, "failed": failures.count, "failures": failures]
        let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        try? data.write(to: directory.appendingPathComponent("results.json")); print(String(decoding: data, as: UTF8.self))
        return failures.isEmpty ? 0 : 1
    }

    @MainActor static func restart(directory: URL, write: Bool) async -> Int32 {
        var passed = 0, failures: [String] = []
        func check(_ name: String, _ value: Bool) { if value { passed += 1 } else { failures.append(name) } }
        func sameLocation(_ actual: URL?, _ expected: URL) -> Bool {
            actual?.resolvingSymlinksInPath().standardizedFileURL == expected.resolvingSymlinksInPath().standardizedFileURL
        }
        do {
            let png = directory.appendingPathComponent("resume.png"), notes = directory.appendingPathComponent("notes.txt")
            if write {
                try fixture(png); try "Restart text\n".write(to: notes, atomically: true, encoding: .utf8)
            }
            let store = EditorDesktopStore(directory: directory.appendingPathComponent("desktop"))
            let app = EditorAppDelegate(recentFiles: RecentLocations(defaults: nil), desktopStore: store, recentFolders: RecentLocations(defaults: nil, kind: .folders))
            let workspace = app.newWindow(tabbed: false)
            if write {
                workspace.setProject(directory); _ = workspace.openDocument(png)
                _ = workspace.executeCommand("split_right"); _ = workspace.executeCommand("focus_next_pane"); _ = workspace.openDocument(notes)
                workspace.window.contentView?.layoutSubtreeIfNeeded()
                try? await Task.sleep(nanoseconds: 150_000_000)
                _ = workspace.executeCommand("focus_next_pane")
                check("Write records selected image and text split", sameLocation(workspace.currentDocument?.fileURL, png) && workspace.documents.count == 2)
                if !failures.isEmpty {
                    let selectedPath = workspace.currentDocument?.fileURL?.path ?? "nil"
                    failures.append("Selected: \(selectedPath); expected: \(png.path); documents: \(workspace.documents.count)")
                }
                try store.saveDesktop(SavedDesktop(workspaces: [workspace.desktopSnapshot]))
                try EditorSession(projectPath: directory.path, selectedIndex: 0, split: false,
                    documents: [EditorSession.Document(document: workspace.currentDocument!, ranges: [])]).save(directory.appendingPathComponent("image.session"))
                check("No image content appears in persisted desktop", (try Data(contentsOf: store.directory.appendingPathComponent("workspace.json"))).count < 8192)
            } else {
                let desktop = try store.loadDesktop()!
                guard let saved = desktop.workspaces.first ?? desktop.lastClosedWorkspace else { throw EditorFailure.invalidEdit("Restart fixture has no workspace") }
                workspace.restoreDesktop(saved)
                check("Fresh process restores image and text tabs", workspace.documents.count == 2 && sameLocation(workspace.currentDocument?.fileURL, png) && workspace.currentTextView == nil)
                check("Fresh process restores the project folder", sameLocation(workspace.projectFolderURL, directory))
                func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                let images = descendants(workspace.window.contentView!).compactMap { $0 as? ImagePreviewView }
                check("Fresh process restores mixed split panes", images.count == 1 && workspace.paneViewsForTesting.count == 2)
                for _ in 0..<50 { if images.first?.loading == false { break }; try? await Task.sleep(nanoseconds: 100_000_000) }
                check("Restored image decodes in the new process", images.first?.decodedPixelSize.width == 320)
                check("Fresh process restores explicit image session", workspace.restoreSession(try EditorSession.load(directory.appendingPathComponent("image.session"))) && sameLocation(workspace.currentDocument?.fileURL, png) && workspace.currentTextView == nil)
            }
            workspace.window.performClose(nil)
        } catch { failures.append(error.localizedDescription) }
        let data = try! JSONSerialization.data(withJSONObject: ["passed": passed, "failed": failures.count, "failures": failures], options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self)); return failures.isEmpty ? 0 : 1
    }
}
