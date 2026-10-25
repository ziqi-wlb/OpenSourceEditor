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

/// The window title and path editor share one titlebar view. The text field is
/// only visible while entering a path, so normal editing uses no content row.
final class FileLocationTitle: NSView, NSTextFieldDelegate {
    let field = NSTextField()
    private let title = NSButton(title: "Source Editor", target: nil, action: nil)
    private let open = NSButton(title: "Open", target: nil, action: nil)
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onEditingChange: (() -> Void)?
    private(set) var isEditing = false
    private var currentPath = ""
    private var floating = false
    private var focusingInput = false
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { !isEditing }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("editor.fileLocation")
        wantsLayer = true
        title.identifier = NSUserInterfaceItemIdentifier("editor.fileLocation.title")
        title.isBordered = false
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.cell?.lineBreakMode = .byTruncatingMiddle
        title.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
        title.imagePosition = .imageLeft
        title.target = self; title.action = #selector(focusInput)
        field.identifier = NSUserInterfaceItemIdentifier("editor.fileLocation.input")
        field.placeholderString = "Open file by name or path…"
        field.font = NSFont.systemFont(ofSize: 12)
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
        for view in [title, field, open] { addSubview(view) }
        field.isHidden = true; open.isHidden = true
        updateTheme()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(title displayTitle: String, path: String?, enabled: Bool) {
        currentPath = path ?? ""
        if title.title != displayTitle { title.title = displayTitle; needsLayout = true }
        title.toolTip = (path.map { $0 + "\n" } ?? "") + "Click to open a file by name or path · ⌥⌘O"
        title.setAccessibilityLabel(displayTitle)
        if !isEditing, field.stringValue != currentPath { field.stringValue = currentPath }
        title.isEnabled = enabled; field.isEnabled = enabled; open.isEnabled = enabled
    }
    func setFloating(_ value: Bool) { floating = value; updateTheme() }
    func updateTheme() {
        layer?.backgroundColor = floating || isEditing ? EditorTheme.panel.cgColor : nil
        layer?.cornerRadius = 5
        field.textColor = EditorTheme.foreground
        title.contentTintColor = EditorTheme.foreground
    }
    @objc func focusInput() {
        guard field.isEnabled else { return }
        focusingInput = true
        defer { focusingInput = false }
        if !isEditing { field.stringValue = currentPath }
        setEditing(true)
        superview?.layoutSubtreeIfNeeded()
        // The current responder is the shared field editor, not the field.
        // Refocusing it would end editing and collapse the title prematurely.
        if field.currentEditor() == nil { window?.makeFirstResponder(field) }
        field.selectText(nil)
    }
    private func setEditing(_ value: Bool) {
        isEditing = value
        title.isHidden = value; field.isHidden = !value; open.isHidden = !value
        updateTheme(); needsLayout = true
        onEditingChange?()
    }
    override func layout() {
        super.layout()
        let width = min(max(180, title.fittingSize.width + 16), max(1, bounds.width - 20))
        let center = window.map { convert(NSPoint(x: $0.frame.width / 2, y: 0), from: nil).x } ?? bounds.midX
        title.frame = NSRect(x: max(10, min(bounds.width - width - 10, center - width / 2)), y: 2, width: width, height: 24)
        field.frame = NSRect(x: 12, y: 5, width: max(1, bounds.width - 84), height: 20)
        open.frame = NSRect(x: max(0, bounds.width - 66), y: 2, width: 56, height: 24)
    }
    func controlTextDidBeginEditing(_ obj: Notification) {
        if !isEditing { setEditing(true) }
        if let editor = field.currentEditor() as? NSTextView {
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false
        }
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        // AppKit can end its previous field-editor session during selectText.
        // That belongs to this focus handoff, not to leaving path-entry mode.
        if !focusingInput { setEditing(false) }
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

/// Owns native titlebar placement. Fullscreen hides the native titlebar, so a
/// shortcut temporarily overlays the same editor at the top of the content.
/// Moving this view never changes the editor's content layout or creates a copy.
final class FileLocationTitlebarController: NSTitlebarAccessoryViewController {
    let location = FileLocationTitle(frame: .zero)
    private weak var ownerWindow: NSWindow?
    private var floating = false

    init() {
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .left
        view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 28))
        location.frame = view.bounds
        location.autoresizingMask = [.width, .height]
        view.addSubview(location)
        location.onEditingChange = { [weak self] in self?.editingChanged() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    func attach(to window: NSWindow) {
        ownerWindow = window
        window.addTitlebarAccessoryViewController(self)
        NotificationCenter.default.addObserver(self, selector: #selector(resize), name: NSWindow.didResizeNotification, object: window)
        resize()
    }
    func focusInput() {
        guard let window = ownerWindow else { return }
        if window.styleMask.contains(.fullScreen), !floating, let content = window.contentView {
            location.removeFromSuperview()
            location.autoresizingMask = []
            content.addSubview(location, positioned: .above, relativeTo: nil)
            floating = true; location.setFloating(true)
            resize()
        }
        location.focusInput()
    }
    private func editingChanged() {
        guard floating, !location.isEditing else { return }
        location.removeFromSuperview()
        view.addSubview(location)
        location.autoresizingMask = [.width, .height]
        location.frame = view.bounds
        floating = false; location.setFloating(false)
    }
    @objc private func resize() {
        guard let window = ownerWindow else { return }
        let width = max(180, window.frame.width - 160)
        view.setFrameSize(NSSize(width: width, height: 28))
        if floating, let content = window.contentView {
            let overlayWidth = min(900, width)
            location.frame = NSRect(x: (content.bounds.width - overlayWidth) / 2,
                y: content.isFlipped ? 0 : content.bounds.height - 28, width: overlayWidth, height: 28)
        } else { location.needsLayout = true }
    }
}
