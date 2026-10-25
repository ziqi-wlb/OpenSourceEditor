import AppKit

enum WorkspaceHomeAction {
    case newFile, openFile, openFolder, newNote, quickOpen, findInProject
    case recentFile(URL), recentFolder(URL)
}

private final class HomeButton: NSButton {
    var invoke: (() -> Void)?
    @objc func performHomeAction() { invoke?() }
}

private final class HomeContent: NSView {
    override var isFlipped: Bool { true }
}

/// Native, bounded presentation. The workspace owns all file/project actions.
final class WorkspaceHomeView: NSScrollView {
    var onAction: ((WorkspaceHomeAction) -> Void)?
    var onExitFocus: (() -> Bool)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, onExitFocus?() == true { return }
        super.keyDown(with: event)
    }
    private let body = HomeContent()
    private let eyebrow = NSTextField(labelWithString: "SOURCE EDITOR")
    private let heading = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(wrappingLabelWithString: "")
    private let filesHeading = NSTextField(labelWithString: "Recent Files")
    private let foldersHeading = NSTextField(labelWithString: "Recent Folders")
    private let hint = NSTextField(wrappingLabelWithString: "⌃⌘B  Toggle sidebar     ·     ⌘P  Quick Open     ·     ⌘⇧P  Commands")
    private var cards: [HomeButton] = []
    private var fileRows: [NSView] = [], folderRows: [NSView] = []
    private struct ContentKey: Equatable {
        let project: URL?
        let files: [URL]
        let folders: [URL]
        let light: Bool
    }
    private var contentKey: ContentKey?

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("workspace.home")
        documentView = body
        hasVerticalScroller = true; autohidesScrollers = true; drawsBackground = false
        for view in [eyebrow, heading, subtitle, filesHeading, foldersHeading, hint] { body.addSubview(view) }
        eyebrow.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        heading.font = NSFont.systemFont(ofSize: 30, weight: .semibold)
        heading.lineBreakMode = .byTruncatingMiddle
        subtitle.font = NSFont.systemFont(ofSize: 13)
        hint.font = NSFont.systemFont(ofSize: 11)
        for label in [filesHeading, foldersHeading] { label.font = NSFont.systemFont(ofSize: 13, weight: .semibold) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(project: URL?, recentFiles: [URL], recentFolders: [URL]) {
        let files = Array(recentFiles.prefix(5)), folders = Array(recentFolders.prefix(5))
        let next = ContentKey(project: project, files: files, folders: folders, light: EditorTheme.isLight)
        guard contentKey != next else { return }
        contentKey = next
        body.wantsLayer = true
        body.layer?.backgroundColor = EditorTheme.background.cgColor
        heading.stringValue = project?.lastPathComponent ?? "Welcome"
        heading.toolTip = project?.path
        subtitle.stringValue = project == nil ? "Open a folder, create a file, or pick up where you left off." : "Your workspace is ready. Choose a file in the sidebar or start something new."
        for label in [eyebrow, subtitle, hint] { label.textColor = EditorTheme.muted }
        for label in [heading, filesHeading, foldersHeading] { label.textColor = EditorTheme.foreground }
        for view in cards + fileRows + folderRows { view.removeFromSuperview() }
        cards = [
            button("New File", detail: "Start editing · ⌘N", symbol: "doc.badge.plus", id: "newFile", action: .newFile),
            button("Open File…", detail: "Browse files · ⌘O", symbol: "doc.text", id: "openFile", action: .openFile),
            button("Open Folder…", detail: "Choose a project", symbol: "folder", id: "openFolder", action: .openFolder),
            button("Markdown Note", detail: "Write notes and preview them", symbol: "square.and.pencil", id: "newNote", action: .newNote),
            button("Quick Open", detail: "Find a project file · ⌘P", symbol: "doc.text.magnifyingglass", id: "quickOpen", action: .quickOpen),
            button("Find in Folder…", detail: "Search project content · ⇧⌘F", symbol: "magnifyingglass", id: "findProject", action: .findInProject)
        ]
        cards[4].isEnabled = project != nil; cards[5].isEnabled = project != nil
        fileRows = rows(files, folder: false)
        folderRows = rows(folders, folder: true)
        for view in cards + fileRows + folderRows { body.addSubview(view) }
        needsLayout = true
    }

    private func button(_ title: String, detail: String, symbol: String, id: String, action: WorkspaceHomeAction) -> HomeButton {
        let button = HomeButton(title: title, target: nil, action: nil)
        button.target = button; button.action = #selector(HomeButton.performHomeAction)
        button.invoke = { [weak self] in self?.onAction?(action) }
        button.identifier = NSUserInterfaceItemIdentifier("home." + id)
        button.setAccessibilityLabel(title); button.toolTip = detail
        button.isBordered = false; button.alignment = .left
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
        button.imagePosition = .imageLeading
        button.contentTintColor = EditorTheme.foreground
        let text = NSMutableAttributedString(string: title + "\n", attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: EditorTheme.foreground])
        text.append(NSAttributedString(string: detail, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: EditorTheme.muted]))
        button.attributedTitle = text
        button.wantsLayer = true; button.layer?.cornerRadius = 10
        button.layer?.backgroundColor = EditorTheme.panel.cgColor
        return button
    }
    private func rows(_ urls: [URL], folder: Bool) -> [NSView] {
        if urls.isEmpty {
            let label = NSTextField(labelWithString: folder ? "No recent folders yet" : "No recent files yet")
            label.font = NSFont.systemFont(ofSize: 12); label.textColor = EditorTheme.muted
            return [label]
        }
        return urls.enumerated().map { index, url in
            let row = button(url.lastPathComponent, detail: url.deletingLastPathComponent().lastPathComponent,
                symbol: folder ? "folder" : "doc.text", id: (folder ? "folder." : "file.") + String(index),
                action: folder ? .recentFolder(url) : .recentFile(url))
            row.toolTip = url.path
            return row
        }
    }

    override func layout() {
        super.layout()
        let width = contentSize.width
        guard width > 0 else { return }
        let padding: CGFloat = width < 600 ? 24 : 48
        let usable = min(860, max(1, width - padding * 2)), x = (width - usable) / 2
        let columns = usable >= 620 ? 2 : 1
        let gap: CGFloat = 14, column = (usable - CGFloat(columns - 1) * gap) / CGFloat(columns)
        eyebrow.frame = NSRect(x: x, y: 36, width: usable, height: 16)
        heading.frame = NSRect(x: x, y: 62, width: usable, height: 42)
        subtitle.frame = NSRect(x: x, y: 116, width: usable, height: 44)
        let cardY: CGFloat = 182
        for (index, card) in cards.enumerated() {
            card.frame = NSRect(x: x + CGFloat(index % columns) * (column + gap), y: cardY + CGFloat(index / columns) * 82, width: column, height: 68)
        }
        let recentY = cardY + CGFloat((cards.count + columns - 1) / columns) * 82 + 24
        func group(_ title: NSTextField, _ rows: [NSView], x: CGFloat, y: CGFloat) -> CGFloat {
            title.frame = NSRect(x: x, y: y, width: column, height: 22)
            for (index, row) in rows.enumerated() { row.frame = NSRect(x: x, y: y + 34 + CGFloat(index) * 54, width: column, height: 46) }
            return y + 34 + CGFloat(rows.count) * 54
        }
        let fileEnd = group(filesHeading, fileRows, x: x, y: recentY)
        let folderEnd = group(foldersHeading, folderRows, x: columns == 2 ? x + column + gap : x, y: columns == 2 ? recentY : fileEnd + 24)
        let bottom = max(fileEnd, folderEnd) + 28
        hint.frame = NSRect(x: x, y: bottom, width: usable, height: 38)
        body.frame = NSRect(x: 0, y: 0, width: width, height: max(contentSize.height, bottom + 64))
    }
}
