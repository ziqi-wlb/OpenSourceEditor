import AppKit

enum EditorSplitAxis: String, Codable { case columns, rows }

// Shared by desktop restoration and sessions; indices refer to the snapshot's
// document list, while paths allow clean files to survive a draft-only snapshot.
struct SavedEditorLayout: Codable {
    struct Pane: Codable {
        var path: String?
        var documentIndex: Int?
        var selections: [[Int]]
        var scrollX: Double
        var scrollY: Double
    }
    var axis: EditorSplitAxis
    var fraction: Double
    var activePane: Int
    var panes: [Pane]

    func validate() throws {
        guard panes.count == 2, panes.indices.contains(activePane),
              fraction.isFinite, (0...1).contains(fraction),
              panes.allSatisfy({ pane in
                  (pane.path.map { $0.hasPrefix("/") } ?? true) &&
                  (pane.documentIndex.map { (0..<256).contains($0) } ?? true) &&
                  pane.scrollX.isFinite && pane.scrollX >= 0 && pane.scrollY.isFinite && pane.scrollY >= 0 &&
                  pane.selections.count <= 4096 && pane.selections.allSatisfy { $0.count == 2 && $0[0] >= 0 && $0[1] >= 0 }
              }) else { throw EditorFailure.invalidEdit("Invalid editor split layout.") }
    }
}

final class EditorSplitToolbar: NSView {
    var onDocument: ((Int, EditorDocument) -> Void)?
    var onAxis: ((EditorSplitAxis) -> Void)?
    var onJoin: (() -> Void)?
    private let first = NSPopUpButton(frame: .zero, pullsDown: false)
    private let second = NSPopUpButton(frame: .zero, pullsDown: false)
    private let orientation = NSSegmentedControl(labels: ["Left / Right", "Top / Bottom"], trackingMode: .selectOne, target: nil, action: nil)
    private let join = NSButton(title: "Single Pane", target: nil, action: nil)
    private struct ContentKey: Equatable {
        var documents: [ObjectIdentifier]
        var titles: [String]
        var panes: [ObjectIdentifier]
        var active: Int
        var axis: EditorSplitAxis
        var light: Bool
    }
    private var key: ContentKey?
    override var isFlipped: Bool { true }
    func height(for width: CGFloat) -> CGFloat { width < 700 ? 66 : 34 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("editor.splitToolbar")
        for (index, popup) in [first, second].enumerated() {
            popup.tag = index
            popup.identifier = NSUserInterfaceItemIdentifier("editor.pane.\(index)")
            popup.font = NSFont.systemFont(ofSize: 12)
            popup.cell?.lineBreakMode = .byTruncatingMiddle
            popup.target = self; popup.action = #selector(chooseDocument(_:))
            addSubview(popup)
        }
        orientation.identifier = NSUserInterfaceItemIdentifier("editor.splitAxis")
        orientation.target = self; orientation.action = #selector(chooseAxis)
        orientation.controlSize = .small
        join.identifier = NSUserInterfaceItemIdentifier("editor.joinPanes")
        join.target = self; join.action = #selector(joinPanes)
        join.bezelStyle = .rounded; join.controlSize = .small
        join.toolTip = "Single Pane · ⌥⌘1"
        addSubview(orientation); addSubview(join)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(documents: [EditorDocument], panes: [EditorDocument], active: Int, axis: EditorSplitAxis) {
        let titles = documents.map { ($0.isModified ? "• " : "") + $0.displayName }
        let next = ContentKey(documents: documents.map(ObjectIdentifier.init), titles: titles,
                              panes: panes.map(ObjectIdentifier.init), active: active, axis: axis, light: EditorTheme.isLight)
        guard key != next else { return }
        key = next
        wantsLayer = true; layer?.backgroundColor = EditorTheme.panel.cgColor
        orientation.selectedSegment = axis == .columns ? 0 : 1
        let names = axis == .columns ? ["Left", "Right"] : ["Top", "Bottom"]
        for (index, popup) in [first, second].enumerated() {
            popup.removeAllItems()
            for (document, title) in zip(documents, titles) {
                let item = NSMenuItem(title: names[index] + ": " + title, action: nil, keyEquivalent: "")
                item.representedObject = document
                item.toolTip = document.fileURL?.path ?? "Unsaved document"
                popup.menu?.addItem(item)
            }
            if panes.indices.contains(index), let selected = documents.firstIndex(where: { $0 === panes[index] }) { popup.selectItem(at: selected) }
            popup.contentTintColor = index == active ? EditorTheme.accent : EditorTheme.foreground
            popup.setAccessibilityLabel(names[index] + " editor file")
        }
        needsLayout = true
    }
    func clearDocuments() {
        guard key != nil else { return }
        first.removeAllItems(); second.removeAllItems(); key = nil
    }
    override func layout() {
        super.layout()
        let narrow = height(for: bounds.width) == 66
        let actions: CGFloat = 290
        let available = max(2, bounds.width - 24 - (narrow ? 0 : actions))
        let width = max(1, (available - 8) / 2)
        first.frame = NSRect(x: 10, y: 4, width: width, height: 26)
        second.frame = NSRect(x: 18 + width, y: 4, width: width, height: 26)
        let y: CGFloat = narrow ? 36 : 6
        let joinWidth = narrow ? min(90, max(24, bounds.width * 0.3)) : 90
        let orientationWidth = narrow ? min(185, max(20, bounds.width - joinWidth - 30)) : 185
        orientation.frame = NSRect(x: narrow ? 10 : bounds.width - actions, y: y, width: orientationWidth, height: 22)
        join.frame = NSRect(x: narrow ? 20 + orientationWidth : bounds.width - 100, y: y, width: joinWidth, height: 22)
    }
    @objc private func chooseDocument(_ sender: NSPopUpButton) {
        if let document = sender.selectedItem?.representedObject as? EditorDocument { onDocument?(sender.tag, document) }
    }
    @objc private func chooseAxis() { onAxis?(orientation.selectedSegment == 0 ? .columns : .rows) }
    @objc private func joinPanes() { onJoin?() }
}
