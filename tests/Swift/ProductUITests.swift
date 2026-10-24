import AppKit
import WebKit

private struct ProductExportChooser: EditorFileChoosing {
    let url: URL
    func choose(_ panel: NSSavePanel, for parent: NSWindow) -> [URL]? { [url] }
}

private final class ProductRecordingChooser: EditorFileChoosing {
    var url: URL?
    var requests = 0
    func choose(_ panel: NSSavePanel, for parent: NSWindow) -> [URL]? {
        requests += 1
        return url.map { [$0] }
    }
}

enum ProductUITests {
    @MainActor static func run(app: EditorAppDelegate, directory: URL) async -> (passed: Int, failed: Int) {
        var passed = 0, failures: [String] = []
        func check(_ name: String, _ value: Bool) { if value { passed += 1 } else { failures.append(name); print("FAIL: " + name) } }
        func pump(_ seconds: Double = 0.1) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        func wait(_ condition: () -> Bool, timeout: Double = 8) async -> Bool {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end { if condition() { return true }; await pump(0.05) }
            return condition()
        }
        func evaluate(_ web: WKWebView, _ script: String) async -> Any? {
            await withCheckedContinuation { continuation in web.evaluateJavaScript(script) { result, error in
                if let error { print("WEB: " + error.localizedDescription) }
                continuation.resume(returning: result)
            } }
        }
        func waitForHeading(_ web: WKWebView, _ title: String) async -> Bool {
            let end = Date().addingTimeInterval(8)
            while Date() < end {
                if await evaluate(web, "document.querySelector('h1')?.textContent") as? String == title { return true }
                await pump(0.05)
            }
            return false
        }
        func capture(_ window: NSWindow, _ filename: String) throws {
            window.contentView?.layoutSubtreeIfNeeded()
            guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming]) else { return }
            let bitmap = NSBitmapImageRep(cgImage: image)
            try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(filename))
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let md = directory.appendingPathComponent("preview.md")
            let plain = directory.appendingPathComponent("notes.txt")
            let source = """
            # Markdown Workspace

            Native **Markdown** with 中文 and 😀. This document stays editable.

            ## Features

            - [x] Edit / preview / side by side
            - [x] Tables and code
            - [ ] Next release

            | Feature | State |
            | :--- | ---: |
            | Live preview | Ready |
            | Project search | Ready |

            ```swift
            let message = "Hello, world"
            print(message)
            ```

            > A native editor with a readable document preview.

            ## Next section

            [Local notes](notes.txt)
            """
            try source.write(to: md, atomically: true, encoding: .utf8)
            try "first\nsearch target 中文 😀\nlast\n".write(to: plain, atomically: true, encoding: .utf8)
            let workspace = app.newWindow(openURLs: [md, plain], projectURL: directory, tabbed: false)
            workspace.selectDocument(0)
            await pump()
            let document = workspace.currentDocument!
            var textView = workspace.currentTextView!
            let chooser = ProductRecordingChooser()
            workspace.fileChooser = chooser
            func outlineButton(in view: NSView) -> NSButton? {
                if let button = view as? NSButton, button.title == "Outline" { return button }
                return view.subviews.lazy.compactMap { outlineButton(in: $0) }.first
            }
            let dirtySource = source + "\n\n## Unsaved outline"
            document.setTextUndoably(dirtySource, actionName: "Outline fixture")
            textView.setSelectedRange(NSRange(location: 4, length: 3))
            let button = workspace.window.contentView.flatMap { outlineButton(in: $0) }
            check("Native Outline button available", button != nil)
            button?.performClick(nil)
            check("Outline opens full preview without source pane", workspace.markdownViewMode == .preview && textView.isHiddenOrHasHiddenAncestor)
            check("Outline renders unsaved heading", await wait { workspace.markdownPreviewForTesting?.page?.headings.last?.title == "Unsaved outline" })
            check("Outline does not ask for build configuration or save", chooser.requests == 0 && workspace.window.attachedSheet == nil && document.isModified && (try? String(contentsOf: md)) == source)
            check("Outline preserves source selection", textView.selectedRange() == NSRange(location: 4, length: 3))
            if let heading = workspace.markdownPreviewForTesting?.page?.headings.last {
                workspace.selectMarkdownHeading(heading)
                check("Heading navigation keeps full preview", workspace.markdownViewMode == .preview && document.position(at: textView.selectedRange().location)?.line == heading.line)
            } else { check("Heading navigation keeps full preview", false) }
            document.undoManager.undo()
            check("Outline preserves native undo", document.storage.string == source && !document.isModified)
            workspace.setMarkdownMode(.edit)
            _ = workspace.executeCommand("build")
            check("Markdown build command renders without configuration", workspace.markdownViewMode == .preview && chooser.requests == 0 && workspace.window.attachedSheet == nil)
            _ = await wait { workspace.markdownPreviewForTesting?.page != nil }
            let marker = directory.appendingPathComponent("configured-build-ran")
            let buildConfig = directory.appendingPathComponent("build.json")
            try JSONSerialization.data(withJSONObject: ["argv": ["/usr/bin/touch", marker.path], "timeoutSeconds": 2]).write(to: buildConfig)
            chooser.url = buildConfig
            workspace.activateMenus()
            let tools = NSApp.mainMenu?.item(withTitle: "Tools")?.submenu
            let chooseBuild = tools?.items.first { $0.action == NSSelectorFromString("chooseBuild") }
            check("Native build configuration action available", chooseBuild.map { NSApp.sendAction($0.action!, to: $0.target, from: $0) } == true && chooser.requests == 1)
            chooser.url = nil
            let runBuild = tools?.items.first { $0.action == NSSelectorFromString("runBuildAction") }
            check("Markdown Tools action says Render Markdown", runBuild.map { workspace.validateMenuItem($0) && $0.title == "Render Markdown" } == true)
            document.setTextUndoably(dirtySource, actionName: "Render fixture")
            workspace.setMarkdownMode(.edit)
            check("Native Markdown Tools action dispatched", runBuild.map { NSApp.sendAction($0.action!, to: $0.target, from: $0) } == true)
            check("Configured Markdown action still renders current buffer", await wait { workspace.markdownPreviewForTesting?.page?.headings.last?.title == "Unsaved outline" })
            check("Markdown rendering skips configured command and autosave", !FileManager.default.fileExists(atPath: marker.path) && chooser.requests == 1 && document.isModified && (try? String(contentsOf: md)) == source)
            workspace.selectDocument(1)
            check("Other syntaxes retain Run Build menu", runBuild.map { workspace.validateMenuItem($0) && $0.title == "Run Build" } == true)
            _ = workspace.executeCommand("build")
            check("Configured command still runs for other syntaxes", await wait { FileManager.default.fileExists(atPath: marker.path) })
            await pump(0.2)
            workspace.selectDocument(0)
            textView = workspace.currentTextView!
            document.undoManager.undo()
            textView.setSelectedRange(NSRange(location: 4, length: 3))
            workspace.setMarkdownMode(.preview)
            check("Preview finishes", await wait { workspace.markdownPreviewForTesting?.page != nil && workspace.markdownPreviewForTesting?.renderedRevision == document.revision })
            if let preview = workspace.markdownPreviewForTesting {
                check("Actual WebKit document displayed", await waitForHeading(preview.webView, "Markdown Workspace"))
                let title = await evaluate(preview.webView, "document.querySelector('h1')?.textContent")
                check("Rendered heading in native web view", title as? String == "Markdown Workspace")
                check("Table and tasks in DOM", (await evaluate(preview.webView, "document.querySelectorAll('table').length + ':' + document.querySelectorAll('input[type=checkbox]').length")) as? String == "1:3")
                check("No document scripts", (await evaluate(preview.webView, "document.querySelectorAll('script').length")) as? Int == 0)
                check("Preview has real viewport", preview.webView.bounds.width > 300 && preview.webView.bounds.height > 300)
                check("Source and selection untouched", document.storage.string == source && !document.isModified && textView.selectedRange() == NSRange(location: 4, length: 3))
                await pump(0.6) // WebKit DOM completion precedes WindowServer compositing.
                try capture(workspace.window, "markdown-preview.png")
            }
            workspace.setMarkdownMode(.sideBySide)
            await pump(0.2)
            check("Side-by-side source visible", !textView.isHiddenOrHasHiddenAncestor && (workspace.markdownPreviewForTesting?.webView.bounds.width ?? 0) > 180)
            if let sourceSplit = textView.enclosingScrollView?.superview, let split = sourceSplit.superview {
                let before = sourceSplit.frame.width
                let local = NSPoint(x: sourceSplit.frame.maxX + 0.5, y: split.bounds.midY)
                let origin = split.convert(local, to: nil)
                let destination = split.convert(NSPoint(x: local.x + 50, y: local.y), to: nil)
                let timestamp = ProcessInfo.processInfo.systemUptime
                func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
                    NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: timestamp,
                        windowNumber: workspace.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                }
                NSApp.postEvent(event(.leftMouseDragged, destination), atStart: false)
                NSApp.postEvent(event(.leftMouseUp, destination), atStart: false)
                workspace.window.sendEvent(event(.leftMouseDown, origin))
                await pump(0.1)
                check("Actual divider drag uses visible geometry", sourceSplit.frame.width > before + 40)
                workspace.setMarkdownMode(.sideBySide)
            }
            workspace.window.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: document.storage.length, length: 0))
            document.undoManager.beginUndoGrouping()
            textView.insertText("\n\n## Live edit", replacementRange: textView.selectedRange())
            document.undoManager.endUndoGrouping()
            check("Native edit reaches preview", await wait { workspace.markdownPreviewForTesting?.renderedRevision == document.revision && workspace.markdownPreviewForTesting?.page?.headings.last?.title == "Live edit" })
            document.undoManager.undo()
            check("Native undo reaches preview", await wait { document.storage.string == source && workspace.markdownPreviewForTesting?.page?.headings.last?.title == "Next section" })
            if let heading = workspace.markdownPreviewForTesting?.page?.headings.last {
                workspace.selectMarkdownHeading(heading)
                check("Outline navigates source", document.position(at: textView.selectedRange().location)?.line == heading.line)
            }
            var light = EditorConfiguration(); light.theme = "light"
            workspace.applyConfiguration(light)
            check("Live theme rerenders", await wait { workspace.markdownPreviewForTesting?.page?.html.contains("data-theme=\"light\"") == true })
            let exported = directory.appendingPathComponent("export.html")
            workspace.fileChooser = ProductExportChooser(url: exported)
            _ = workspace.executeCommand("markdown_export")
            check("Native export command writes HTML", (try? String(contentsOf: exported)).map { $0.contains("<table>") && !$0.contains("source-editor-link:") } == true)
            await pump(0.6)
            try capture(workspace.window, "markdown-side-by-side-light.png")
            weak var oldPreview = workspace.markdownPreviewForTesting
            workspace.selectDocument(1)
            await pump(0.3)
            check("Preview released on plain-text tab", workspace.markdownPreviewForTesting == nil && oldPreview == nil && workspace.markdownViewMode == .edit)
            workspace.selectDocument(0)
            check("Per-document view mode restored", workspace.markdownViewMode == .sideBySide)
            check("Restored preview finishes", await wait { workspace.markdownPreviewForTesting?.page != nil })
            document.setTextUndoably("# stale\n" + String(repeating: "body **text**\n", count: 10_000), actionName: "Fixture")
            document.setTextUndoably("# latest", actionName: "Fixture")
            check("Latest generation wins", await wait { workspace.markdownPreviewForTesting?.page?.headings.first?.title == "latest" })
            workspace.setMarkdownMode(.edit)
            weak var search: ProjectSearchPanel?
            _ = workspace.executeCommand("find_in_project")
            await pump(0.2)
            search = workspace.projectSearchForTesting
            check("Project search is attached sheet", workspace.projectSearchForTesting?.panel.sheetParent === workspace.window)
            workspace.projectSearchForTesting?.searchForTesting("search target")
            check("Real project search completes", await wait { workspace.projectSearchForTesting?.report != nil })
            check("Project search finds disk text", workspace.projectSearchForTesting?.report?.hits.first?.line == 2)
            workspace.projectSearchForTesting?.openFirstForTesting()
            await pump(0.3)
            check("Project search opens exact native selection", workspace.currentDocument?.fileURL == plain.standardizedFileURL.resolvingSymlinksInPath() && workspace.currentTextView?.selectedRange() == NSRange(location: 6, length: "search target".utf16.count))
            check("Search controller released", workspace.projectSearchForTesting == nil && search == nil && workspace.window.attachedSheet == nil)
            let editView = workspace.currentTextView!
            let editDoc = workspace.currentDocument!
            let editSource = editDoc.storage.string
            editView.setSelectedRange(NSRange(location: 6, length: 0))
            _ = workspace.executeCommand("duplicate_lines")
            check("Native duplicate changes shared buffer", editDoc.storage.string.components(separatedBy: "search target").count == 3)
            editDoc.undoManager.undo()
            check("Line edit restores text and cursor in one undo", editDoc.storage.string == editSource && editView.selectedRange() == NSRange(location: 6, length: 0))
            var codeSettings = editDoc.settings; codeSettings.syntax = "python"; try editDoc.updateSettings(codeSettings)
            _ = workspace.executeCommand("toggle_comment")
            check("Native comment command uses syntax", editDoc.storage.string.contains("# search target"))
            editDoc.undoManager.undo()
            check("Comment is one native undo", editDoc.storage.string == editSource)
            document.checkpoint()
            let recoveryFolder = directory.appendingPathComponent("recovery", isDirectory: true)
            workspace.setAutoRecovery(true, directory: recoveryFolder)
            editDoc.setTextUndoably("unsaved 中文😀", actionName: "Recovery fixture")
            workspace.updateRecoveryForTesting()
            let recoveryURL = workspace.recoveryURLForTesting!
            check("Async recovery writes unsaved buffer", await wait { (try? EditorSession.load(recoveryURL))?.documents.contains { $0.text == "unsaved 中文😀" } == true })
            let abandoned = recoveryFolder.appendingPathComponent("abandoned.json")
            try FileManager.default.copyItem(at: recoveryURL, to: abandoned)
            do { _ = try workspace.restoreRecoverySnapshot(recoveryURL); check("Live recovery snapshot rejected", false) }
            catch { check("Live recovery snapshot rejected", true) }
            try "new disk text".write(to: plain, atomically: true, encoding: .utf8)
            let recovered = try workspace.restoreRecoverySnapshot(abandoned)
            check("Recovery opens separate window and protects changed disk", recovered !== workspace && recovered.currentDocument?.fileURL == nil && recovered.currentDocument?.storage.string == "unsaved 中文😀" && recovered.currentDocument?.isModified == true)
            for recoveredDocument in recovered.documents { recoveredDocument.checkpoint() }
            recovered.window.performClose(nil)
            editDoc.checkpoint()
            workspace.updateRecoveryForTesting()
            check("Saving clears stale recovery snapshot", await wait { !FileManager.default.fileExists(atPath: recoveryURL.path) })
            editDoc.setTextUndoably("late snapshot", actionName: "Recovery fixture")
            workspace.updateRecoveryForTesting()
            editDoc.checkpoint()
            workspace.setAutoRecovery(false)
            check("Final cleanup defeats late recovery write", await wait { workspace.recoveryURLForTesting == nil && !FileManager.default.fileExists(atPath: recoveryURL.path) })
            workspace.setAutoRecovery(true, directory: recoveryFolder)
            editDoc.setTextUndoably("closing snapshot", actionName: "Recovery fixture")
            workspace.updateRecoveryForTesting()
            let closingRecoveryURL = workspace.recoveryURLForTesting!
            workspace.currentDocument?.checkpoint()
            workspace.selectDocument(0)
            document.checkpoint()
            workspace.setMarkdownMode(.sideBySide)
            _ = await wait { workspace.markdownPreviewForTesting?.page != nil }
            weak var closingPreview = workspace.markdownPreviewForTesting
            workspace.window.performClose(nil)
            check("Window close cancels and releases preview", await wait { closingPreview == nil && !workspace.window.isVisible })
            check("Window close awaits final recovery cleanup", workspace.recoveryURLForTesting == nil && !FileManager.default.fileExists(atPath: closingRecoveryURL.path))
        } catch { failures.append(error.localizedDescription) }
        let result: [String: Any] = ["passed": passed, "failed": failures.count, "failures": failures]
        let data = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try? data.write(to: directory.appendingPathComponent("results.json"))
        print(String(data: data, encoding: .utf8)!)
        return (passed, failures.count)
    }
}
