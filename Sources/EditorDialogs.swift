import AppKit

/// Owns the selected URLs separately from the native panel's presentation.
protocol EditorFileChoosing {
    func choose(_ panel: NSSavePanel, for parent: NSWindow) -> [URL]?
}

struct NativeEditorFileChooser: EditorFileChoosing {
    func choose(_ panel: NSSavePanel, for parent: NSWindow) -> [URL]? {
        guard EditorDialogs.run(panel, for: parent) == .OK else { return nil }
        if let openPanel = panel as? NSOpenPanel { return openPanel.urls }
        return panel.url.map { [$0] }
    }
}

/// Owns window association and modal cleanup for every editor dialog.
/// The synchronous result keeps existing save/close transactions sequential.
enum EditorDialogs {
    @discardableResult
    static func addCancelButton(to alert: NSAlert) -> NSButton {
        let button = alert.addButton(withTitle: "Cancel")
        button.keyEquivalent = "\u{1b}"
        return button
    }

    static func run(_ alert: NSAlert, for parent: NSWindow, cancelButton: NSButton? = nil) -> NSApplication.ModalResponse {
        run(window: alert.window, parent: parent, cancel: {
            (cancelButton ?? (alert.buttons.count == 1 ? alert.buttons.first : nil))?.performClick(nil)
        }) { finish in
            alert.beginSheetModal(for: parent, completionHandler: finish)
        }
    }

    static func run(_ panel: NSSavePanel, for parent: NSWindow) -> NSApplication.ModalResponse {
        run(window: panel, parent: parent, cancel: { panel.cancel(nil) }) { finish in
            panel.beginSheetModal(for: parent, completionHandler: finish)
        }
    }

    private static func run(window: NSWindow, parent: NSWindow,
                            cancel: @escaping () -> Void,
                            begin: (@escaping (NSApplication.ModalResponse) -> Void) -> Void) -> NSApplication.ModalResponse {
        let responder = parent.firstResponder
        window.appearance = parent.appearance
        if parent.isMiniaturized { parent.deminiaturize(nil) }
        parent.makeKeyAndOrderFront(nil)
        // Field editors and remote file-panel views may consume Escape before
        // button shortcuts. Route it once, while this owned dialog is modal.
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53, NSApp.modalWindow === window else { return event }
            cancel()
            return nil
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        begin { response in
            // A canceled modal session must not stop a later, unrelated dialog.
            if NSApp.modalWindow === window { NSApp.stopModal(withCode: response) }
        }
        let response = NSApp.runModal(for: window)
        if window.sheetParent === parent {
            if response.rawValue < 0 { cancel() }
            if window.sheetParent === parent { parent.endSheet(window, returnCode: response) }
        }
        window.orderOut(nil)
        if parent.isVisible {
            parent.makeKey()
            if let responder { parent.makeFirstResponder(responder) }
        }
        return response
    }
}
