import AppKit

/// Resolves explicit local paths and exact file names against the existing
/// project index. Never walks the project tree or interprets shell expressions.
enum FileLocationResolver {
    static func resolve(_ input: String, project: URL?, currentFile: URL?, knownFiles: [URL]) throws -> [URL] {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("\0"), !text.contains("\n"), !text.contains("\r") else {
            throw EditorFailure.invalidEdit("Enter a file name or local file path.")
        }
        let explicit: URL?
        if text.hasPrefix("file:") {
            guard let url = URL(string: text), url.isFileURL, url.path.hasPrefix("/"),
                  url.host == nil || url.host == "" || url.host == "localhost",
                  url.query == nil, url.fragment == nil else {
                throw EditorFailure.invalidEdit("Enter a local file URL without a query or fragment.")
            }
            explicit = URL(fileURLWithPath: url.path)
        } else if text.contains("://") {
            throw EditorFailure.invalidEdit("Only local file names and paths can be opened here.")
        } else if text.hasPrefix("/") || text.hasPrefix("~/") {
            explicit = URL(fileURLWithPath: (text as NSString).expandingTildeInPath)
        } else {
            explicit = nil
        }
        let base = project ?? currentFile?.deletingLastPathComponent()
        var candidates: [URL] = []
        if let explicit { candidates = [explicit] }
        else if text.contains("/") {
            guard let base else { throw EditorFailure.invalidEdit("Open a folder first, or enter an absolute file path.") }
            candidates = [base.appendingPathComponent(text)]
        } else {
            candidates = knownFiles.filter { $0.lastPathComponent == text }
            if let base {
                let direct = base.appendingPathComponent(text)
                if FileManager.default.fileExists(atPath: direct.path) { candidates.append(direct) }
            }
        }
        var seen = Set<URL>()
        candidates = candidates.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            .filter { seen.insert($0).inserted }
            .sorted { $0.path < $1.path }
        guard !candidates.isEmpty else {
            throw EditorFailure.invalidEdit("File not found. Enter its path, or use Quick Open to search the indexed project.")
        }
        if candidates.count == 1, let url = candidates.first {
            // Already-open files remain selectable even if their disk file has
            // disappeared. The document owner handles external disk changes.
            let known = knownFiles.contains { $0 == url }
            if !known {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
                guard values.isDirectory != true else {
                    throw EditorFailure.invalidEdit("This path is a folder. Use Open Folder… to open it.")
                }
                guard values.isRegularFile == true else { throw EditorFailure.invalidEdit("This path is not a regular file.") }
            }
        }
        return candidates
    }
}

final class FileLocationBar: NSView, NSTextFieldDelegate {
    let field = NSTextField()
    private let icon = NSImageView()
    private let open = NSButton(title: "Open", target: nil, action: nil)
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onEditingChange: (() -> Void)?
    private(set) var isEditing = false
    private var currentPath = ""
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("editor.fileLocation")
        wantsLayer = true
        icon.image = NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: "Open file by name or path")
        field.identifier = NSUserInterfaceItemIdentifier("editor.fileLocation.input")
        field.placeholderString = "Open file by name or path…"
        field.font = NSFont.systemFont(ofSize: 12)
        field.focusRingType = .none
        field.isBezeled = false; field.drawsBackground = false
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        field.setAccessibilityLabel("File name or path")
        field.toolTip = "Enter a full file name, project-relative path, absolute path or ~/… · ⌥⌘O"
        open.identifier = NSUserInterfaceItemIdentifier("editor.fileLocation.open")
        open.bezelStyle = .rounded; open.controlSize = .small
        open.target = self; open.action = #selector(submit)
        open.toolTip = "Open the entered file · Return"
        for view in [icon, field, open] { addSubview(view) }
        updateTheme()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(path: String?, enabled: Bool) {
        currentPath = path ?? ""
        if !isEditing, field.stringValue != currentPath { field.stringValue = currentPath }
        field.isEnabled = enabled; open.isEnabled = enabled
    }
    func updateTheme() {
        layer?.backgroundColor = EditorTheme.panel.cgColor
        field.textColor = EditorTheme.foreground
        icon.contentTintColor = EditorTheme.muted
    }
    func focusInput() {
        guard field.isEnabled else { return }
        isEditing = true
        onEditingChange?()
        superview?.layoutSubtreeIfNeeded()
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }
    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 12, y: 9, width: 16, height: 16)
        field.frame = NSRect(x: 36, y: 8, width: max(1, bounds.width - 108), height: 20)
        open.frame = NSRect(x: max(0, bounds.width - 66), y: 5, width: 56, height: 24)
    }
    func controlTextDidBeginEditing(_ obj: Notification) {
        isEditing = true
        if let editor = field.currentEditor() as? NSTextView {
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false
        }
        onEditingChange?()
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        isEditing = false
        onEditingChange?()
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        switch NSStringFromSelector(commandSelector) {
        case "insertNewline:": submit(); return true
        case "cancelOperation:":
            field.stringValue = currentPath
            onCancel?()
            return true
        default: return false
        }
    }
    @objc private func submit() { onSubmit?(field.stringValue) }
}
