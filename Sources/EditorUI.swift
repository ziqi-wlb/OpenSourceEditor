import AppKit
import UniformTypeIdentifiers

private final class EditorMenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}

private enum TabCloseScope: CaseIterable {
    case others, right, unmodified
    var title: String {
        switch self {
        case .others: return "Close Other Tabs"
        case .right: return "Close Tabs to the Right"
        case .unmodified: return "Close Unmodified Tabs"
        }
    }
}

private final class ContextMenuButton: NSButton {
    var makeContextMenu: (() -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? { makeContextMenu?() }
}

private final class ContextOutlineView: NSOutlineView {
    var makeContextMenu: ((Int) -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        return makeContextMenu?(row)
    }
}

private final class ProjectItem: NSObject {
    let url: URL
    let isDirectory: Bool
    private var loadedChildren: [ProjectItem]?

    init(_ url: URL) {
        self.url = URL(fileURLWithPath: url.path).standardizedFileURL
        self.isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    var children: [ProjectItem] {
        guard isDirectory else { return [] }
        if let loadedChildren { return loadedChildren }
        let urls = (try? FileManager.default.contentsOfDirectory(at: url,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let result = urls.map(ProjectItem.init).sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
        loadedChildren = result
        return result
    }
}

private final class EditorTextView: NSTextView {
    var onFocus: (() -> Void)?
    var makeContextMenu: (() -> NSMenu?)?
    var onPasteImage: ((Data) -> Void)?
    weak var document: EditorDocument?
    private var ownedSelections: [NSValue]?
    private var applyingSelections = false

    // AppKit collapses multiple zero-length ranges to one insertion point. Keep
    // the complete cursor set at this boundary and expose it to every consumer.
    override var selectedRanges: [NSValue] {
        get { ownedSelections ?? super.selectedRanges }
        set { setSelectedRanges(newValue, affinity: .downstream, stillSelecting: false) }
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        applyingSelections = true
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        applyingSelections = false
        ownedSelections = ranges.count > 1 ? ranges : nil
        needsDisplay = true
    }

    override func setSelectedRange(_ charRange: NSRange) {
        if !applyingSelections { ownedSelections = nil }
        super.setSelectedRange(charRange)
        needsDisplay = true
    }

    override func setSelectedRange(_ charRange: NSRange, affinity: NSSelectionAffinity, stillSelecting: Bool) {
        if !applyingSelections { ownedSelections = nil }
        super.setSelectedRange(charRange, affinity: affinity, stillSelecting: stillSelecting)
        needsDisplay = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        return makeContextMenu?()
    }

    override func mouseDown(with event: NSEvent) {
        ownedSelections = nil
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48, event.modifierFlags.contains(.shift),
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            insertBacktab(self)
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ranges = ownedSelections, let layout = layoutManager else { return }
        insertionPointColor.setFill()
        for range in ranges.dropFirst().map(\.rangeValue) where range.length == 0 {
            var fragment: NSRect
            var x: CGFloat
            if range.location >= (string as NSString).length {
                if layout.extraLineFragmentRect.height > 0 {
                    fragment = layout.extraLineFragmentRect
                    x = fragment.minX
                } else if layout.numberOfGlyphs > 0 {
                    let glyph = layout.numberOfGlyphs - 1
                    fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                    x = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer!).maxX
                } else { continue }
            } else {
                let glyph = layout.glyphIndexForCharacter(at: range.location)
                fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                x = fragment.minX + layout.location(forGlyphAt: glyph).x
            }
            NSRect(x: x + textContainerOrigin.x, y: fragment.minY + textContainerOrigin.y,
                   width: 1.5, height: fragment.height).fill()
        }
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onFocus?() }
        return result
    }

    // NSTextView exposes multiple selections; explicitly apply typing to each selection
    // so cursor selection and document edits have the same behavior.
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let ranges = selectedRanges.map(\.rangeValue)
        guard replacementRange.location == NSNotFound, ranges.count > 1,
              let text = (insertString as? String) ?? (insertString as? NSAttributedString)?.string else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        guard let document, admitMultipleChange(ranges: ranges, replacements: Array(repeating: text, count: ranges.count)) else { return }
        breakUndoCoalescing()
        let result = TextOperations.apply(in: string, edits: ranges.map { TextReplacement(range: $0, text: text) })
        guard result.error == nil else { NSSound.beep(); return }
        Self.applyCursorTransaction(document: document, text: result.text, selections: result.selections,
                                    inverseSelections: ranges, editor: self, name: "Multiple Cursor Edit")
        breakUndoCoalescing()
    }

    override func deleteBackward(_ sender: Any?) { deleteMultiple(backward: true, sender: sender) }
    override func deleteForward(_ sender: Any?) { deleteMultiple(backward: false, sender: sender) }

    override func cut(_ sender: Any?) {
        let ranges = selectedRanges.map(\.rangeValue)
        guard ranges.count > 1 else { super.cut(sender); return }
        guard isEditable, ranges.contains(where: { $0.length > 0 }) else { return }
        copy(sender)
        applyEditorResult(TextOperations.apply(in: string, edits: ranges.map {
            TextReplacement(range: $0, text: "")
        }), name: "Cut")
    }

    override func paste(_ sender: Any?) {
        guard isEditable else { return }
        if document?.resolvedSyntax == .markdown, let handler = onPasteImage,
           let image = NSPasteboard.general.data(forType: .png) ?? NSPasteboard.general.data(forType: .tiff) {
            handler(image); return
        }
        guard selectedRanges.count > 1, let text = NSPasteboard.general.string(forType: .string) else {
            super.paste(sender)
            return
        }
        // AppKit supplies a concrete replacement range when pasting. Route a
        // multi-selection paste through the same atomic edit as typed text.
        insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    override func insertTab(_ sender: Any?) { insertIndentation(backtab: false) }
    override func insertBacktab(_ sender: Any?) { insertIndentation(backtab: true) }
    override func insertNewline(_ sender: Any?) {
        if hasMarkedText() { super.insertNewline(sender); return }
        guard let document else { super.insertNewline(sender); return }
        let ranges = selectedRanges.map(\.rangeValue)
        let result = document.resolvedSyntax == .markdown ? NoteEditing.newline(in: string, selections: ranges, settings: document.settings) :
            TextOperations.insertNewline(in: string, selections: ranges, settings: document.settings, syntax: document.resolvedSyntax)
        applyEditorResult(result, name: "Insert Newline")
    }

    private func insertIndentation(backtab: Bool) {
        guard let document else { return }
        applyEditorResult(TextOperations.insertTab(in: string, selections: selectedRanges.map(\.rangeValue),
                                                   settings: document.settings, backtab: backtab),
                          name: backtab ? "Unindent" : "Indent")
    }

    func applyEditorResult(_ result: TextEditResult, name: String) {
        guard let document, result.error == nil else { NSSound.beep(); return }
        let prior = selectedRanges.map(\.rangeValue)
        guard result.text != string else {
            if !result.selections.isEmpty { selectedRanges = result.selections.map { NSValue(range: $0) } }
            return
        }
        let full = NSRange(location: 0, length: (string as NSString).length)
        guard admitMultipleChange(ranges: [full], replacements: [result.text]) else { return }
        breakUndoCoalescing()
        Self.applyCursorTransaction(document: document, text: result.text, selections: result.selections,
                                    inverseSelections: prior, editor: self, name: name)
        breakUndoCoalescing()
    }

    private func deleteMultiple(backward: Bool, sender: Any?) {
        let ranges = selectedRanges.map(\.rangeValue)
        if let document, document.settings.translateTabsToSpaces && document.settings.useTabStops {
            let result = backward ? TextOperations.deleteBackward(in: string, selections: ranges, settings: document.settings) :
                TextOperations.deleteForward(in: string, selections: ranges, settings: document.settings)
            applyEditorResult(result, name: "Delete")
            return
        }
        guard ranges.count > 1, let document else {
            if backward { super.deleteBackward(sender) } else { super.deleteForward(sender) }
            return
        }
        let source = string as NSString
        let edits = ranges.compactMap { range -> TextReplacement? in
            if range.length > 0 { return TextReplacement(range: range, text: "") }
            if backward, range.location > 0 {
                return TextReplacement(range: source.rangeOfComposedCharacterSequence(at: range.location - 1), text: "")
            }
            if !backward, range.location < source.length {
                return TextReplacement(range: source.rangeOfComposedCharacterSequence(at: range.location), text: "")
            }
            return nil
        }
        guard !edits.isEmpty, admitMultipleChange(ranges: edits.map(\.range), replacements: Array(repeating: "", count: edits.count)) else { return }
        breakUndoCoalescing()
        let result = TextOperations.apply(in: string, edits: edits)
        guard result.error == nil else { NSSound.beep(); return }
        Self.applyCursorTransaction(document: document, text: result.text, selections: result.selections,
                                    inverseSelections: ranges, editor: self, name: "Multiple Cursor Delete")
        breakUndoCoalescing()
    }

    private func admitMultipleChange(ranges: [NSRange], replacements: [String]) -> Bool {
        undoManager?.disableUndoRegistration()
        defer { undoManager?.enableUndoRegistration() }
        return shouldChangeText(inRanges: ranges.map { NSValue(range: $0) }, replacementStrings: replacements)
    }

    private static func applyCursorTransaction(document: EditorDocument, text: String, selections: [NSRange],
                                               inverseSelections: [NSRange], editor: EditorTextView?, name: String) {
        let editor = editor?.document === document ? editor : nil
        let previous = document.storage.string
        let priorSelections = editor?.selectedRanges.map(\.rangeValue) ?? inverseSelections
        let undo = document.undoManager
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: document) { [weak editor] document in
            applyCursorTransaction(document: document, text: previous, selections: priorSelections,
                                   inverseSelections: selections, editor: editor, name: name)
        }
        undo.disableUndoRegistration()
        document.setTextUndoably(text, actionName: name)
        undo.enableUndoRegistration()
        editor?.selectedRanges = selections.map { NSValue(range: $0) }
        editor?.didChangeText()
        undo.setActionName(name)
        undo.endUndoGrouping()
    }
}

private final class LineNumberRuler: NSRulerView {
    weak var editor: NSTextView?
    private(set) var visibleLineNumbers: [Int] = []
    override var isFlipped: Bool { true }

    init(scrollView: NSScrollView, editor: NSTextView) {
        self.editor = editor
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = editor
        ruleThickness = 54
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        EditorTheme.background.setFill()
        bounds.fill()
        visibleLineNumbers = []
        guard let editor, let layout = editor.layoutManager, let container = editor.textContainer else { return }
        let length = editor.textStorage?.length ?? editor.string.utf16.count
        let index = (editor as? EditorTextView)?.document?.lineIndex ?? DocumentLineIndex(editor.string as NSString)
        let logicalStarts = index.starts
        let visible = editor.visibleRect.offsetBy(dx: -editor.textContainerOrigin.x,
                                                 dy: -editor.textContainerOrigin.y)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let start = min(characters.location, length)
        var lineIndex = index.lineIndex(at: start)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: EditorTheme.muted,
        ]
        repeat {
            let lineStart = logicalStarts[lineIndex]
            let lineRect: NSRect
            if length == 0 || lineStart == length {
                lineRect = layout.extraLineFragmentRect
            } else {
                let glyph = layout.glyphIndexForCharacter(at: lineStart)
                lineRect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            }
            let y = lineRect.minY + editor.textContainerOrigin.y - editor.visibleRect.minY + 1
            visibleLineNumbers.append(lineIndex + 1)
            let label = String(lineIndex + 1) as NSString
            let width = label.size(withAttributes: attributes).width
            label.draw(at: NSPoint(x: ruleThickness - width - 12, y: y), withAttributes: attributes)
            lineIndex += 1
        } while lineIndex < logicalStarts.count && logicalStarts[lineIndex] <= min(length, NSMaxRange(characters))
    }
}

private final class EditorScrollView: NSScrollView {
    override func layout() {
        super.layout()
        let viewport = contentView.bounds.size
        guard let text = documentView as? NSTextView, let container = text.textContainer,
              viewport.width > 0, viewport.height > 0 else { return }
        let minimum = NSSize(width: 0, height: viewport.height)
        if text.minSize != minimum { text.minSize = minimum }
        var size = text.frame.size
        if container.widthTracksTextView { size.width = max(64, viewport.width) }
        size.height = max(size.height, viewport.height)
        if size != text.frame.size { text.setFrameSize(size) }
        // TextKit owns the document extent and estimates unlaid text. Resolving
        // the entire container here defeats its viewport layout on every resize.
        if !container.widthTracksTextView && text.frame.width < viewport.width {
            text.setFrameSize(NSSize(width: viewport.width, height: text.frame.height))
        }
    }
}

private final class SingleColumnScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let tree = documentView as? NSTableView, contentView.bounds.width > 0 else { return }
        let width = contentView.bounds.width
        // The viewport owns width; the table or outline continues to own row height.
        if tree.frame.width != width {
            tree.setFrameSize(NSSize(width: width, height: tree.frame.height))
        }
        if let column = tree.tableColumns.first, column.width != width { column.width = width }
    }
}

/// Frame layout, divider painting and drag hit testing share one geometry owner.
/// NSSplitView's internal divider state cannot track externally assigned frames.
private final class EditorSplitView: NSView {
    private var fraction: CGFloat = 0.5
    var isVertical = false
    var dividerStyle = NSSplitView.DividerStyle.thin
    var dividerThickness: CGFloat { dividerStyle == .thin ? 1 : 6 }
    var arrangedSubviews: [NSView] { subviews }
    override var isFlipped: Bool { true }
    func addArrangedSubview(_ view: NSView) { addSubview(view); needsLayout = true; needsDisplay = true }
    func removeArrangedSubview(_ view: NSView) { view.removeFromSuperview(); needsLayout = true; needsDisplay = true }
    private var dividerRect: NSRect? {
        let visible = arrangedSubviews.filter { !$0.isHidden }
        guard visible.count == 2 else { return nil }
        return isVertical ? NSRect(x: visible[0].frame.maxX, y: 0, width: dividerThickness, height: bounds.height)
            : NSRect(x: 0, y: visible[0].frame.maxY, width: bounds.width, height: dividerThickness)
    }
    private var dragRect: NSRect? { dividerRect?.insetBy(dx: isVertical ? -3 : 0, dy: isVertical ? 0 : -3) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let divider = dividerRect else { return }
        NSGraphicsContext.saveGraphicsState()
        bounds.clip()
        NSColor.separatorColor.setFill()
        divider.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        if dragRect?.contains(convert(point, from: superview)) == true { return self }
        return super.hitTest(point)
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        if let rect = dragRect { addCursorRect(rect, cursor: isVertical ? .resizeLeftRight : .resizeUpDown) }
    }
    override func mouseDown(with event: NSEvent) {
        guard dragRect?.contains(convert(event.locationInWindow, from: nil)) == true else { super.mouseDown(with: event); return }
        while let next = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp { break }
            let point = convert(next.locationInWindow, from: nil)
            setPosition(isVertical ? point.x : point.y, ofDividerAt: 0)
            window?.contentView?.layoutSubtreeIfNeeded()
        }
    }

    func adjustSubviews() {
        let visible = arrangedSubviews.filter { !$0.isHidden }
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard visible.count == 2 else {
            for view in visible where view.frame != bounds { view.frame = bounds; view.needsLayout = true }
            return
        }
        let extent = (isVertical ? bounds.width : bounds.height) - dividerThickness
        let minimum = min(120, extent / 2)
        let first = max(minimum, min(extent - minimum, extent * fraction))
        let frames: [NSRect]
        if isVertical {
            frames = [NSRect(x: 0, y: 0, width: first, height: bounds.height),
                      NSRect(x: first + dividerThickness, y: 0, width: extent - first, height: bounds.height)]
        } else {
            frames = [NSRect(x: 0, y: 0, width: bounds.width, height: first),
                      NSRect(x: 0, y: first + dividerThickness, width: bounds.width, height: extent - first)]
        }
        for (view, frame) in zip(visible, frames) where view.frame != frame { view.frame = frame; view.needsLayout = true }
    }

    override func layout() {
        super.layout()
        adjustSubviews()
    }

    func setPosition(_ position: CGFloat, ofDividerAt dividerIndex: Int) {
        let extent = (isVertical ? bounds.width : bounds.height) - dividerThickness
        if extent > 0 { fraction = max(0, min(1, position / extent)) }
        adjustSubviews()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    func useFraction(_ value: CGFloat) { fraction = value; adjustSubviews(); needsLayout = true; needsDisplay = true }
}

private final class FrameLayoutView: NSView {
    var arrange: ((NSSize) -> Void)?
    override var isFlipped: Bool { true }
    override func layout() { super.layout(); arrange?(bounds.size) }
}

private final class EditorPane: NSObject {
    let document: EditorDocument
    let scroll = EditorScrollView()
    let textView: EditorTextView
    let layout: NSLayoutManager
    let ruler: LineNumberRuler
    private var highlightWork: DispatchWorkItem?
    private var highlightedRanges: [NSRange] = []
    private var highlightedViewport: NSRange?

    init(document: EditorDocument, delegate: NSTextViewDelegate, focus: @escaping () -> Void) {
        self.document = document
        scroll.clipsToBounds = true
        layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true
        let initialFrame = NSRect(x: 0, y: 0, width: 640, height: 400)
        scroll.frame = initialFrame
        let container = NSTextContainer(containerSize: NSSize(width: 616, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        document.storage.addLayoutManager(layout)
        textView = EditorTextView(frame: initialFrame, textContainer: container)
        ruler = LineNumberRuler(scrollView: scroll, editor: textView)
        super.init()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = true
        scroll.backgroundColor = EditorTheme.background
        scroll.autohidesScrollers = true
        scroll.documentView = textView
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        textView.delegate = delegate
        textView.document = document
        textView.onFocus = focus
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.allowsUndo = true
        textView.font = EditorTheme.font
        textView.textColor = EditorTheme.foreground
        textView.backgroundColor = EditorTheme.background
        textView.insertionPointColor = EditorTheme.accent
        textView.selectedTextAttributes = [.backgroundColor: NSColor(calibratedRed: 0.18, green: 0.32, blue: 0.48, alpha: 1)]
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.minSize = NSSize(width: 0, height: initialFrame.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = []
        container.widthTracksTextView = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        scroll.contentView.postsBoundsChangedNotifications = true
        scheduleHighlight()
    }

    deinit {
        highlightWork?.cancel()
        NotificationCenter.default.removeObserver(self)
        document.storage.removeLayoutManager(layout)
    }

    @objc private func scrolled() { scheduleHighlight(delay: 0.03, relayout: false) }

    func scheduleHighlight(delay: Double = 0.15, relayout: Bool = true) {
        highlightWork?.cancel()
        if relayout { highlightedViewport = nil }
        let work = DispatchWorkItem { [weak self] in self?.highlight() }
        highlightWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        ruler.needsDisplay = true
        if relayout { scroll.needsLayout = true }
    }

    func applyConfiguration(_ configuration: EditorConfiguration) {
        let font = NSFont(name: configuration.fontName, size: CGFloat(configuration.fontSize)) ??
            NSFont.monospacedSystemFont(ofSize: CGFloat(configuration.fontSize), weight: .regular)
        textView.font = font
        textView.typingAttributes[.font] = font
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = []
        paragraph.defaultTabInterval = (" " as NSString).size(withAttributes: [.font: font]).width * CGFloat(document.settings.tabSize)
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes[.paragraphStyle] = paragraph
        let entire = NSRange(location: 0, length: document.storage.length)
        document.storage.addAttribute(.font, value: font, range: entire)
        document.storage.addAttribute(.paragraphStyle, value: paragraph, range: entire)
        let wraps = configuration.wrapsText(isSourceCode: document.syntaxIsSourceCode)
        scroll.hasHorizontalScroller = !wraps
        textView.isHorizontallyResizable = !wraps
        textView.textContainer?.widthTracksTextView = wraps
        textView.textContainer?.containerSize = NSSize(width: wraps ? max(64, textView.bounds.width) : CGFloat.greatestFiniteMagnitude,
                                                      height: CGFloat.greatestFiniteMagnitude)
        textView.backgroundColor = EditorTheme.background
        textView.textColor = EditorTheme.foreground
        scroll.backgroundColor = EditorTheme.background
        scheduleHighlight()
    }

    private func highlight() {
        let range = NSRange(location: 0, length: document.storage.length)
        if highlightedViewport == nil && !highlightedRanges.isEmpty {
            // Edits shift temporary ranges. Clear the invalidated presentation
            // once, then scrolling only replaces the previous viewport ranges.
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
            highlightedRanges.removeAll(keepingCapacity: true)
        }
        let highlights = document.syntaxHighlights
        guard !highlights.groups.isEmpty, let container = textView.textContainer else {
            highlightedViewport = NSRange(location: 0, length: 0)
            return
        }
        let visible = textView.visibleRect.offsetBy(dx: -textView.textContainerOrigin.x, dy: -textView.textContainerOrigin.y)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let lower = max(0, characters.location - 2048)
        let upper = min(range.length, NSMaxRange(characters) + 2048)
        let viewport = NSRange(location: lower, length: max(0, upper - lower))
        if highlightedViewport == viewport { return }
        for oldRange in highlightedRanges { layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: oldRange) }
        highlightedRanges.removeAll(keepingCapacity: true)
        let colors = [NSColor.systemPurple, .systemOrange, .systemGreen, EditorTheme.muted]
        for (group, color) in colors.enumerated() {
            for token in highlights.matches(in: viewport, group: group) {
                layout.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: token)
                highlightedRanges.append(token)
            }
        }
        highlightedViewport = viewport
    }
}

private struct PaletteChoice {
    let title: String
    let detail: String
    let action: () -> Void
}

private final class PaletteField: NSSearchField {
    var onAccept: (() -> Void)?
    var onMove: ((Int) -> Void)?
    var onDismiss: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onAccept?()
        case 125: onMove?(1)
        case 126: onMove?(-1)
        case 53: onDismiss?()
        default: super.keyDown(with: event)
        }
    }
}

private final class CommandPalette: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let panel: NSPanel
    let field = PaletteField()
    let table = NSTableView()
    let footer = NSTextField(labelWithString: "↑↓ Choose    ↩ Open    Esc Dismiss")
    private var choices: [PaletteChoice] = []
    private var filtered: [PaletteChoice] = []
    private var onQuery: ((String) -> Void)?
    private weak var parentWindow: NSWindow?
    private weak var previousResponder: NSResponder?

    init(parent: NSWindow) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 650, height: 430),
                        styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        parentWindow = parent
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.level = .normal
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.backgroundColor = EditorTheme.panel
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isReleasedWhenClosed = false
        let content = NSView()
        panel.contentView = content
        field.placeholderString = "Type a command"
        field.font = NSFont.systemFont(ofSize: 18)
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.onAccept = { [weak self] in self?.accept() }
        field.onMove = { [weak self] delta in self?.move(delta) }
        field.onDismiss = { [weak self] in self?.dismiss() }
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("choice")))
        table.headerView = nil
        table.rowHeight = 47
        table.backgroundColor = EditorTheme.panel
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(accept)
        let scroll = SingleColumnScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        footer.font = NSFont.systemFont(ofSize: 11)
        footer.textColor = EditorTheme.muted
        for view in [field, scroll, footer] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            field.heightAnchor.constraint(equalToConstant: 34),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(parentFrameChanged), name: NSWindow.didMoveNotification, object: parent)
        NotificationCenter.default.addObserver(self, selector: #selector(parentFrameChanged), name: NSWindow.didResizeNotification, object: parent)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func parentFrameChanged() { if panel.isVisible { position() } }

    private func position() {
        guard let parent = parentWindow, let screen = parent.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let size = NSSize(width: min(650, visible.width), height: min(430, visible.height))
        let x = min(max(parent.frame.midX - size.width / 2, visible.minX), visible.maxX - size.width)
        let y = min(max(parent.frame.maxY - size.height - 64, visible.minY), visible.maxY - size.height)
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    func show(title: String, choices: [PaletteChoice], query: ((String) -> Void)? = nil) {
        self.choices = choices
        self.onQuery = query
        field.placeholderString = title
        field.stringValue = ""
        filter()
        guard let parent = parentWindow, parent.attachedSheet == nil else { return }
        if !panel.isVisible { previousResponder = parent.firstResponder }
        position()
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    func replaceChoices(_ choices: [PaletteChoice]) { self.choices = choices; filter() }

    func updateTheme() {
        panel.appearance = NSAppearance(named: EditorTheme.isLight ? .aqua : .darkAqua)
        panel.backgroundColor = EditorTheme.panel
        table.backgroundColor = EditorTheme.panel
        footer.textColor = EditorTheme.muted
        table.reloadData()
    }

    func dismiss() {
        let wasVisible = panel.isVisible
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if wasVisible, let parent = parentWindow, parent.isVisible {
            parent.makeKey()
            if let previousResponder { parent.makeFirstResponder(previousResponder) }
        }
        previousResponder = nil
    }

    func controlTextDidChange(_ obj: Notification) {
        if let onQuery { onQuery(field.stringValue) }
        else { filter() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch NSStringFromSelector(commandSelector) {
        case "moveDown:": move(1); return true
        case "moveUp:": move(-1); return true
        case "insertNewline:": accept(); return true
        case "cancelOperation:": dismiss(); return true
        default: return false
        }
    }

    private func filter() {
        let tokens = field.stringValue.lowercased().split(separator: " ")
        filtered = choices.filter { choice in
            let value = (choice.title + " " + choice.detail).lowercased()
            return tokens.allSatisfy { value.contains($0) }
        }
        table.reloadData()
        if !filtered.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        footer.stringValue = "\(filtered.count) results    ↑↓ Choose    ↩ Open    Esc Dismiss"
    }

    private func move(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        let row = max(0, min(filtered.count - 1, table.selectedRow + delta))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func accept() {
        let row = table.selectedRow
        guard filtered.indices.contains(row) else { return }
        let action = filtered[row].action
        dismiss()
        action()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filtered.indices.contains(row) else { return nil }
        let view = NSTableCellView()
        let title = NSTextField(labelWithString: filtered[row].title)
        title.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.textColor = EditorTheme.foreground
        let detail = NSTextField(labelWithString: filtered[row].detail)
        detail.font = NSFont.systemFont(ofSize: 11)
        detail.textColor = EditorTheme.muted
        detail.lineBreakMode = .byTruncatingMiddle
        for item in [title, detail] { item.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(item) }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: 5),
            title.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
        ])
        return view
    }
}

final class EditorWorkspace: NSObject, NSWindowDelegate,
    NSTextViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate, NSMenuItemValidation {
    weak var applicationOwner: EditorAppDelegate?
    private var mainMenu: NSMenu?
    private var windowMenu: NSMenu?
    private(set) var window: NSWindow!
    private(set) var documents: [EditorDocument] = []
    private(set) var selectedIndex = 0
    private var panes: [EditorPane] = []
    private var activePane = 0
    private var splitEnabled = false
    private var projectRoot: ProjectItem?
    private var projectDocument: EditorProject?
    private var projectFiles: [URL] = []
    private var projectIndexWork: ProjectIndexOperation?
    private var projectIndexGeneration = 0
    private var projectSearchPanel: ProjectSearchPanel?
    private var selectionCache: [ObjectIdentifier: [NSValue]] = [:]
    private let projectSplit = EditorSplitView()
    private let workSplit = EditorSplitView()
    private let editorSplit = EditorSplitView()
    private let contentSplit = EditorSplitView()
    private let markdownBar = NSStackView()
    private let markdownModes = NSSegmentedControl(labels: ["Edit", "Preview", "Side by Side"], trackingMode: .selectOne, target: nil, action: nil)
    private let markdownInfo = NSTextField(labelWithString: "Markdown")
    private let markdownOutline = NSButton(title: "Outline", target: nil, action: nil)
    private let markdownExport = NSButton(title: "Export HTML…", target: nil, action: nil)
    private var markdownPreview: MarkdownPreviewView?
    private var pendingMarkdownOutline: ObjectIdentifier?
    private var recovery: EditorRecovery?
    private var recoveryTimer: Timer?
    private var recoverySignature = ""
    private var recoveryMenuItem: NSMenuItem?
    private var recoveryMessage = "Auto recovery is off"
    private var markdownModeCache: [ObjectIdentifier: MarkdownViewMode] = [:]
    private let tabs = NSStackView()
    private let outline = ContextOutlineView()
    private let projectLabel = NSTextField(labelWithString: "OPEN FILES")
    private let status = EditorStatusBar()
    private var statusMenuSignature = ""
    #if EDITOR_TESTS
    private var menuActionCount = 0
    private var lastMenuActionID = ""
    #endif
    private var saveEncodingMenu: NSMenu?
    private var reopenEncodingMenu: NSMenu?
    private var mainIndentationMenu: NSMenu?
    private var mainLineEndingMenu: NSMenu?
    private var mainSyntaxMenu: NSMenu?
    private var recentFilesMenu: NSMenu?
    #if EDITOR_TESTS
    private(set) var lastContextMenu: NSMenu?
    #endif
    private let recentFiles: RecentFiles
    var fileChooser: EditorFileChoosing
    private var closedFileURLs: [URL] = []
    private let findBar = NSStackView()
    private let replaceRow = NSStackView()
    private struct FindKey: Equatable {
        let document: ObjectIdentifier
        let revision: UInt64
        let query: String
        let regex: Bool
        let caseSensitive: Bool
    }
    private let searchWorker = LatestSearchWorker()
    private var searchDebounce: DispatchWorkItem?
    private var searchGeneration = 0
    private var requestedFindKey: FindKey?
    private var cachedFindKey: FindKey?
    private var cachedFindRanges: [NSRange] = []
    private var pendingFindAction: (() -> Void)?
    private let findField = NSSearchField()
    private let replaceField = NSTextField()
    private let regexToggle = NSButton(checkboxWithTitle: ".*", target: nil, action: nil)
    private let caseToggle = NSButton(checkboxWithTitle: "Aa", target: nil, action: nil)
    private let findMessage = NSTextField(labelWithString: "")
    private var palette: CommandPalette!
    private let outputArea = FrameLayoutView()
    private var editorArea: FrameLayoutView!
    private let outputView = NSTextView()
    private let outputTitle = NSTextField(labelWithString: "OUTPUT")
    private var buildRunner = BuildRunner()
    private var pluginRunner: BuildRunner?
    private var outputWasTrimmed = false
    private var buildSpec: BuildSpec?
    private var buildSpecURL: URL?
    private var isBuildRunning = false
    private var isPluginRunning = false
    private var pendingTermination = false
    private var pendingWindowClose = false
    private var configuration: EditorConfiguration?
    private var pluginURL: URL?
    private var pythonURL = URL(fileURLWithPath: "/usr/bin/python3")
    private var pluginCommand = ""
    private var started = false
    private var closed = false
    private var fileMonitor: EditorFileMonitor?
    private var monitoredPaths: Set<URL> = []
    private var fileMonitoringEnabled = false
    private let diskQueue: OperationQueue = {
        let queue = OperationQueue(); queue.name = "SourceEditor.DiskCheck"; queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility; return queue
    }()
    private var diskChecks: [ObjectIdentifier: DiskCheckOperation] = [:]
    private var diskChanges: [ObjectIdentifier: String] = [:]
    private let noticeBar = NSStackView()
    private let noticeLabel = NSTextField(labelWithString: "")
    private let noticeButton = NSButton(title: "Review", target: nil, action: nil)
    private var noticeAction: (() -> Void)?
    private var noticeKind: String?

    func showNotice(_ message: String, actionTitle: String? = nil, kind: String? = nil, action: (() -> Void)? = nil) {
        guard !pendingTermination, !pendingWindowClose else { return }
        noticeLabel.stringValue = message
        noticeLabel.toolTip = message
        noticeAction = action
        noticeKind = kind
        noticeButton.title = actionTitle ?? "Review"
        noticeButton.isHidden = action == nil
        noticeBar.isHidden = false
        editorArea?.needsLayout = true
    }
    @objc private func performNoticeAction() { noticeAction?() }
    @objc private func findRecoverySnapshots() {
        let candidates = RecoveryCandidate.discover()
        if candidates.isEmpty { showNotice("No abandoned recovery snapshots found.") }
        else {
            showNotice("\(candidates.count) recovery snapshot(s) available", actionTitle: "Recover…") { [weak self] in self?.showRecoveryCandidates(candidates) }
            showRecoveryCandidates(candidates)
        }
    }
    @objc private func dismissNotice() {
        noticeBar.isHidden = true; noticeAction = nil; noticeKind = nil; editorArea?.needsLayout = true
    }

    func offerRecoverySnapshots(directory: URL = EditorRecovery.defaultDirectory) {
        let candidates = RecoveryCandidate.discover(in: directory)
        guard !candidates.isEmpty, noticeBar.isHidden else { return }
        showNotice("\(candidates.count) recovery snapshot(s) available", actionTitle: "Recover…") { [weak self] in
            self?.showRecoveryCandidates(candidates)
        }
    }
    private func showRecoveryCandidates(_ candidates: [RecoveryCandidate]) {
        let menu = NSMenu(title: "Recovery snapshots")
        menu.autoenablesItems = false
        for candidate in candidates {
            let date = DateFormatter.localizedString(from: candidate.modified, dateStyle: .short, timeStyle: .short)
            let item = actionItem("\(date) · \(ByteCountFormatter.string(fromByteCount: Int64(candidate.bytes), countStyle: .file))") { [weak self] in
                guard let self else { return }
                do { _ = try self.restoreRecoverySnapshot(candidate.url) }
                catch { self.showError(error) }
            }
            item.toolTip = candidate.url.path
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: noticeButton.bounds.maxY), in: noticeButton)
    }

    var desktopSnapshot: SavedWorkspace {
        if let document = currentDocument, let view = currentTextView { selectionCache[ObjectIdentifier(document)] = view.selectedRanges }
        let files = documents.compactMap { document -> SavedWorkspace.File? in
            guard let path = document.fileURL?.path else { return nil }
            return .init(path: path, settings: document.settings, encoding: document.diskEncoding,
                selections: Array((selectionCache[ObjectIdentifier(document)]?.map { [$0.rangeValue.location, $0.rangeValue.length] } ?? [[0, 0]]).prefix(4096)),
                markdownMode: String(describing: markdownModeCache[ObjectIdentifier(document)] ?? .edit))
        }
        let rect = window.frame
        return .init(files: files, selectedPath: currentDocument?.fileURL?.path, projectPath: projectRoot?.url.path,
            split: splitEnabled, sidebarVisible: projectSplit.arrangedSubviews.first?.isHidden == false,
            frame: [Double(rect.origin.x), Double(rect.origin.y), Double(rect.width), Double(rect.height)],
            scrollY: Double(currentTextView?.enclosingScrollView?.contentView.bounds.origin.y ?? 0))
    }

    func restoreDesktop(_ saved: SavedWorkspace) {
        var restored: [EditorDocument] = []
        var failures: [String] = []
        for file in saved.files {
            do {
                let document = try EditorDocument.open(URL(fileURLWithPath: file.path), encoding: file.encoding, settings: file.settings)
                restored.append(document)
                let ranges = file.selections.compactMap { pair -> NSValue? in
                    guard pair.count == 2, pair[0] >= 0, pair[1] >= 0, pair[0] <= document.storage.length,
                          pair[1] <= document.storage.length - pair[0] else { return nil }
                    let range = NSRange(location: pair[0], length: pair[1])
                    guard Range(range, in: document.storage.string) != nil else { return nil }
                    return NSValue(range: range)
                }
                selectionCache[ObjectIdentifier(document)] = ranges.isEmpty ? [NSValue(range: NSRange(location: 0, length: 0))] : ranges
                markdownModeCache[ObjectIdentifier(document)] = file.markdownMode == "preview" ? .preview : file.markdownMode == "sideBySide" ? .sideBySide : .edit
                noteRecentFile(document.fileURL!)
            } catch { failures.append(URL(fileURLWithPath: file.path).lastPathComponent + ": " + error.localizedDescription) }
        }
        if !restored.isEmpty {
            for view in editorSplit.arrangedSubviews { editorSplit.removeArrangedSubview(view); view.removeFromSuperview() }
            panes.removeAll()
            documents = restored
            selectedIndex = restored.firstIndex { $0.fileURL?.path == saved.selectedPath } ?? 0
            splitEnabled = saved.split
            rebuildPanes(); rebuildTabs()
        }
        if let path = saved.projectPath, FileManager.default.fileExists(atPath: path) { setProject(URL(fileURLWithPath: path, isDirectory: true)) }
        projectSplit.arrangedSubviews.first?.isHidden = !saved.sidebarVisible
        if saved.frame.count == 4 {
            let rect = NSRect(x: saved.frame[0], y: saved.frame[1], width: max(760, min(10000, saved.frame[2])), height: max(420, min(10000, saved.frame[3])))
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) { window.setFrame(rect, display: true) }
        }
        window.contentView?.layoutSubtreeIfNeeded()
        if let view = currentTextView { view.scroll(NSPoint(x: 0, y: min(CGFloat(saved.scrollY), max(0, view.bounds.height - (view.enclosingScrollView?.contentSize.height ?? 0))))) }
        updateStatus()
        refreshFileMonitor()
        if !failures.isEmpty { showNotice("Some files could not be restored: " + failures.joined(separator: "; ")) }
    }

    init(recentFiles: RecentFiles = RecentFiles(), fileChooser: EditorFileChoosing = NativeEditorFileChooser()) {
        self.recentFiles = recentFiles
        self.fileChooser = fileChooser
        super.init()
    }

    var currentDocument: EditorDocument? {
        documents.indices.contains(selectedIndex) ? documents[selectedIndex] : nil
    }

    var currentTextView: NSTextView? {
        if let text = window?.firstResponder as? EditorTextView, panes.contains(where: { $0.textView === text }) { return text }
        return panes.indices.contains(activePane) ? panes[activePane].textView : panes.first?.textView
    }

    func start(openURLs: [URL], projectURL: URL?, initialConfiguration: EditorConfiguration? = nil) {
        guard !started else { return }
        started = true
        configuration = initialConfiguration
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: EditorTheme.isLight ? .aqua : .darkAqua)
        makeMenus()
        makeWindow()
        palette = CommandPalette(parent: window)
        NotificationCenter.default.addObserver(self, selector: #selector(documentChanged(_:)),
                                               name: .editorDocumentChanged, object: nil)
        for url in openURLs { openDocument(url) }
        if documents.isEmpty { addDocument(EditorDocument(settings: documentDefaults)) }
        if let projectURL { setProject(projectURL) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(currentTextView)
        #if !EDITOR_TESTS
        if UserDefaults.standard.bool(forKey: "autoRecovery") { setAutoRecovery(true) }
        startFileMonitoring()
        #endif
    }

    func startFileMonitoring() { fileMonitoringEnabled = true; refreshFileMonitor() }
    private func refreshFileMonitor() {
        guard fileMonitoringEnabled, !closed, !pendingTermination, !pendingWindowClose else { return }
        let paths = Set((projectRoot.map { [$0.url] } ?? []) + documents.compactMap { $0.fileURL?.deletingLastPathComponent() })
        guard paths != monitoredPaths else { return }
        fileMonitor?.stop(); monitoredPaths = paths
        fileMonitor = EditorFileMonitor(paths: Array(paths)) { [weak self] urls in self?.filesChanged(urls) }
    }
    private func filesChanged(_ urls: [URL]) {
        guard !closed, !pendingTermination, !pendingWindowClose else { return }
        for document in documents {
            guard let url = document.fileURL, urls.contains(where: { url.path == $0.path || url.path.hasPrefix($0.path + "/") }) else { continue }
            let identity = ObjectIdentifier(document), revision = document.revision
            diskChecks[identity]?.cancel()
            let work = DiskCheckOperation(url: url, digest: document.diskDigestHex, encoding: document.diskEncoding)
            diskChecks[identity] = work
            work.completionBlock = { [weak self, weak document, weak work] in
                guard let work, !work.isCancelled else { return }
                let result = work.result
                DispatchQueue.main.async {
                    guard let self, let document, !self.closed, !self.pendingTermination, !self.pendingWindowClose,
                          self.documents.contains(where: { $0 === document }), document.fileURL == url,
                          self.diskChecks[identity] === work else { return }
                    self.diskChecks.removeValue(forKey: identity)
                    switch result {
                    case .unchanged: self.diskChanges.removeValue(forKey: identity)
                    case .changed(let text, let encoding, let digest):
                        if !document.isModified, document.revision == revision, document.diskDigestHex == work.digest {
                            document.acceptExternalText(text, encoding: encoding, digest: digest)
                            self.clampSelections(document)
                            self.diskChanges.removeValue(forKey: identity)
                        } else { self.diskChanges[identity] = "\(document.displayName) changed on disk; your unsaved text is preserved." }
                    case .missing: self.diskChanges[identity] = "\(document.displayName) was moved or deleted. Use Save As to keep your buffer."
                    case .unavailable(let reason): self.diskChanges[identity] = "Cannot check \(document.displayName): " + reason
                    }
                    self.updateStatus()
                    if !self.diskChanges.isEmpty {
                        self.showNotice(self.diskChanges.values.sorted().joined(separator: " · "), actionTitle: "Review…", kind: "disk") { [weak self] in self?.reviewDiskChange() }
                    } else if self.noticeKind == "disk" { self.dismissNotice() }
                }
            }
            diskQueue.addOperation(work)
        }
        if let root = projectRoot?.url, urls.contains(where: { url in
            (url.path == root.path || url.path.hasPrefix(root.path + "/")) &&
                !url.pathComponents.dropFirst(root.pathComponents.count).contains(where: { [".git", ".build", "node_modules", "__pycache__"].contains($0) })
        }) { refreshProject() }
    }
    private func clampSelections(_ document: EditorDocument) {
        func valid(_ ranges: [NSValue]) -> [NSValue] {
            let values = ranges.filter { let range = $0.rangeValue; return range.location <= document.storage.length && range.length <= document.storage.length - range.location && Range(range, in: document.storage.string) != nil }
            return values.isEmpty ? [NSValue(range: NSRange(location: 0, length: 0))] : values
        }
        let identity = ObjectIdentifier(document)
        selectionCache[identity] = valid(selectionCache[identity] ?? [])
        for pane in panes where pane.document === document { pane.textView.selectedRanges = valid(pane.textView.selectedRanges) }
    }
    private func reviewDiskChange() {
        guard let document = documents.first(where: { diskChanges[ObjectIdentifier($0)] != nil }),
              let index = documents.firstIndex(where: { $0 === document }) else { return }
        selectDocument(index)
        let alert = NSAlert()
        alert.messageText = "External file change"
        alert.informativeText = diskChanges[ObjectIdentifier(document)] ?? ""
        alert.addButton(withTitle: "Keep Buffer")
        alert.addButton(withTitle: "Reload from Disk…")
        let cancel = EditorDialogs.addCancelButton(to: alert)
        if runDialog(alert, cancelButton: cancel) == .alertSecondButtonReturn, revertCurrentDocument() {
            diskChanges.removeValue(forKey: ObjectIdentifier(document))
            dismissNotice()
        }
    }

    private func refreshProject() {
        guard let root = projectRoot?.url else { return }
        let expanded = Set((0..<outline.numberOfRows).compactMap { row -> String? in
            guard let item = outline.item(atRow: row) as? ProjectItem, outline.isItemExpanded(item) else { return nil }
            return item.url.path
        })
        let selected = outline.selectedRow >= 0 ? (outline.item(atRow: outline.selectedRow) as? ProjectItem)?.url : nil
        setProject(root)
        func expand(_ node: ProjectItem) {
            guard expanded.contains(node.url.path) else { return }
            outline.expandItem(node)
            for child in node.children where child.isDirectory { expand(child) }
        }
        if let projectRoot { expand(projectRoot) }
        if let selected, let row = (0..<outline.numberOfRows).first(where: { (outline.item(atRow: $0) as? ProjectItem)?.url == selected }) {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    @discardableResult
    func createProjectItem(in parent: URL, name: String, directory: Bool) throws -> URL {
        guard let root = projectRoot?.url else { throw EditorFailure.invalidEdit("Open a project folder first.") }
        let target = try ProjectFileOperations(root: root).create(in: parent, name: name, directory: directory)
        refreshProject()
        if !directory { openDocument(target) }
        return target
    }
    func moveProjectItem(_ source: URL, to destination: URL) throws {
        guard let root = projectRoot?.url else { throw EditorFailure.invalidEdit("Open a project folder first.") }
        let workspaces = applicationOwner?.workspaces ?? [self]
        let affected = workspaces.flatMap(\.documents).compactMap { document -> (EditorDocument, URL)? in
            guard let url = document.fileURL, let next = ProjectFileOperations.rebase(url, from: source, to: destination) else { return nil }
            return (document, next)
        }
        guard !affected.contains(where: { entry in workspaces.flatMap(\.documents).contains(where: { other in other !== entry.0 && other.fileURL == entry.1 && !affected.contains(where: { $0.0 === other }) }) }) else {
            throw EditorFailure.invalidEdit("The destination is already open in another buffer.")
        }
        _ = try ProjectFileOperations(root: root).move(source, to: destination)
        for (document, next) in affected { document.relocate(to: next) }
        recentFiles.relocate(from: source, to: destination)
        for workspace in workspaces {
            if let old = workspace.projectRoot?.url, let next = ProjectFileOperations.rebase(old, from: source, to: destination) { workspace.setProject(next) }
            else { workspace.refreshProject() }
            workspace.refreshFileMonitor(); workspace.rebuildTabs()
        }
    }
    @discardableResult func trashProjectItem(_ source: URL) throws -> URL? {
        guard let root = projectRoot?.url else { throw EditorFailure.invalidEdit("Open a project folder first.") }
        let workspaces = applicationOwner?.workspaces ?? [self]
        let affected = workspaces.flatMap(\.documents).filter { $0.fileURL.flatMap { ProjectFileOperations.rebase($0, from: source, to: source) } != nil }
        let trashed = try ProjectFileOperations(root: root).trash(source)
        for document in affected { document.detachAfterTrash() }
        for workspace in workspaces { workspace.refreshProject(); workspace.refreshFileMonitor(); workspace.rebuildTabs() }
        return trashed
    }

    private func promptProjectName(title: String, initial: String) -> String? {
        let alert = NSAlert(); alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 26)); field.stringValue = initial
        alert.accessoryView = field
        let submit = alert.addButton(withTitle: "Continue"), cancel = EditorDialogs.addCancelButton(to: alert)
        configureAlertInputs([field], firstResponder: field, submitButton: submit, alert: alert)
        return runDialog(alert, cancelButton: cancel) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    var hasRunningWork: Bool { isBuildRunning || isPluginRunning || recovery != nil }

    func confirmDocumentsBeforeClosing() -> Bool {
        window.makeKeyAndOrderFront(nil)
        for document in documents where document.isModified {
            if !confirmClose(document) { return false }
        }
        return true
    }

    func prepareForApplicationTermination() {
        pendingTermination = true
        freezeForClose()
        if isBuildRunning { buildRunner.cancel() }
        if isPluginRunning { pluginRunner?.cancel() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !pendingTermination, !pendingWindowClose, confirmDocumentsBeforeClosing() else { return false }
        if hasRunningWork {
            pendingWindowClose = true
            freezeForClose()
            if isBuildRunning { buildRunner.cancel() }
            if isPluginRunning { pluginRunner?.cancel() }
            return false
        }
        return true
    }

    func windowDidBecomeKey(_ notification: Notification) { activateMenus() }

    func activateMenus() {
        if let mainMenu { NSApp.mainMenu = mainMenu; NSApp.windowsMenu = windowMenu }
        refreshRecentFilesMenu()
        updateStatus()
    }

    func windowWillClose(_ notification: Notification) {
        closed = true
        searchDebounce?.cancel(); searchWorker.cancel(); pendingFindAction = nil
        fileMonitor?.stop(); fileMonitor = nil; diskQueue.cancelAllOperations(); diskChecks.removeAll()
        palette?.dismiss()
        releaseMarkdownPreview()
        projectIndexWork?.cancel()
        projectSearchPanel?.close()
        projectSearchPanel = nil
        NotificationCenter.default.removeObserver(self)
        applicationOwner?.windowClosed(self)
    }

    deinit {
        projectIndexWork?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func newWindow() { applicationOwner?.newWindow() }
    @objc private func mergeWindows() { applicationOwner?.mergeWindows() }

    private func makeMenus() {
        let main = NSMenu()
        mainMenu = main
        func menu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let result = NSMenu(title: title)
            item.submenu = result
            main.addItem(item)
            return result
        }
        func item(_ menu: NSMenu, _ title: String, _ selector: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) {
            let equivalent = modifiers.contains(.shift) ? key.uppercased() : key
            let value = NSMenuItem(title: title, action: selector, keyEquivalent: equivalent)
            value.keyEquivalentModifierMask = modifiers
            value.target = self
            menu.addItem(value)
        }
        let app = menu("Source Editor")
        item(app, "About Source Editor", #selector(showAbout))
        item(app, "Load Configuration…", #selector(loadConfiguration))
        item(app, "Save Configuration…", #selector(saveConfiguration))
        item(app, "Reset Configuration", #selector(resetConfiguration))
        app.addItem(.separator())
        item(app, "Quit Source Editor", #selector(quit), "q")
        let file = menu("File")
        item(file, "New File", #selector(newFile), "n")
        item(file, "New Window", #selector(newWindow), "n", [.command, .shift])
        item(file, "Open…", #selector(openFile), "o")
        item(file, "Open Folder…", #selector(openFolder), "o", [.command, .shift])
        let recent = NSMenu(title: "Open Recent")
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recentItem.submenu = recent
        file.addItem(recentItem)
        recentFilesMenu = recent
        refreshRecentFilesMenu()
        item(file, "Open Project File…", #selector(openProjectFile))
        item(file, "Save Project As…", #selector(saveProjectAs))
        file.addItem(.separator())
        item(file, "Save", #selector(saveFile), "s")
        item(file, "Save As…", #selector(saveAs), "s", [.command, .shift])
        item(file, "Save All", #selector(saveAll), "s", [.command, .option])
        item(file, "Revert File…", #selector(revertFile))
        saveEncodingMenu = NSMenu(title: "Save with Encoding")
        let saveEncoded = NSMenuItem(title: "Save with Encoding", action: nil, keyEquivalent: "")
        saveEncoded.submenu = saveEncodingMenu
        file.addItem(saveEncoded)
        reopenEncodingMenu = NSMenu(title: "Reopen with Encoding")
        let reopenEncoded = NSMenuItem(title: "Reopen with Encoding", action: nil, keyEquivalent: "")
        reopenEncoded.submenu = reopenEncodingMenu
        file.addItem(reopenEncoded)
        file.addItem(.separator())
        item(file, "Close Tab", #selector(closeTab), "w")
        let closeWindow = NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "W")
        closeWindow.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(closeWindow)
        item(file, "Reopen Closed File", #selector(reopenClosedFile), "t", [.command, .shift])
        file.addItem(.separator())
        item(file, "Copy File Path", #selector(copyFilePath))
        item(file, "Copy Relative File Path", #selector(copyRelativeFilePath))
        item(file, "Copy File Name", #selector(copyFileName))
        item(file, "Open Containing Folder…", #selector(revealCurrentFile))
        item(file, "Reveal in Side Bar", #selector(revealCurrentFileInSidebar))
        file.addItem(.separator())
        item(file, "Save Session…", #selector(saveSession))
        item(file, "Restore Session…", #selector(loadSession))
        let recoveryMenu = NSMenu(title: "Recovery")
        recoveryMenuItem = NSMenuItem(title: "Enable Auto Recovery", action: #selector(toggleAutoRecovery), keyEquivalent: "")
        recoveryMenuItem?.target = self
        recoveryMenu.addItem(recoveryMenuItem!)
        item(recoveryMenu, "Recover Snapshot in New Window…", #selector(recoverSnapshot))
        item(recoveryMenu, "Find Recovery Snapshots…", #selector(findRecoverySnapshots))
        item(recoveryMenu, "Show Recovery Folder", #selector(revealRecoveryFolder))
        let recoveryItem = NSMenuItem(title: "Recovery", action: nil, keyEquivalent: "")
        recoveryItem.submenu = recoveryMenu
        file.addItem(recoveryItem)
        let edit = menu("Edit")
        for (title, selector, key) in [("Undo", Selector(("undo:")), "z"), ("Redo", Selector(("redo:")), "Z"),
                                      ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"),
                                      ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            let value = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            edit.addItem(value)
        }
        edit.addItem(.separator())
        item(edit, "Select Next Occurrence", #selector(selectNextOccurrence), "d")
        item(edit, "Select All Occurrences", #selector(selectAllOccurrences), "g", [.command, .control])
        edit.addItem(.separator())
        item(edit, "Toggle Comment", #selector(toggleComment), "/")
        item(edit, "Duplicate Lines", #selector(duplicateLines), "d", [.command, .shift])
        item(edit, "Delete Lines", #selector(deleteLines), "k", [.command, .shift])
        item(edit, "Move Lines Up", #selector(moveLinesUp), "\u{f700}", [.option])
        item(edit, "Move Lines Down", #selector(moveLinesDown), "\u{f701}", [.option])
        item(edit, "Sort Lines", #selector(sortLines))
        item(edit, "Sort Lines (Case Sensitive)", #selector(sortCaseSensitive))
        item(edit, "Reverse Sort Lines", #selector(sortReverse))
        item(edit, "Unique Sorted Lines", #selector(sortUnique))
        item(edit, "Uppercase", #selector(uppercase))
        item(edit, "Lowercase", #selector(lowercase))
        let find = menu("Find")
        item(find, "Find…", #selector(showFind), "f")
        item(find, "Find in Project…", #selector(findInProject), "f", [.command, .shift])
        item(find, "Find Next", #selector(findNext), "g")
        item(find, "Find Previous", #selector(findPrevious), "g", [.command, .shift])
        item(find, "Replace…", #selector(showReplace), "f", [.command, .option])
        let view = menu("View")
        item(view, "Command Palette…", #selector(showCommands), "p", [.command, .shift])
        item(view, "Quick Open…", #selector(quickOpen), "p")
        item(view, "Go to Line…", #selector(goToLine), "l")
        let fontMenu = NSMenu(title: "Font")
        let fontItem = NSMenuItem(title: "Font", action: nil, keyEquivalent: "")
        fontItem.submenu = fontMenu
        view.addItem(fontItem)
        item(fontMenu, "Larger", #selector(increaseFontSize), "+")
        item(fontMenu, "Smaller", #selector(decreaseFontSize), "-")
        item(fontMenu, "Reset", #selector(resetFontSize))
        for (title, keyPath) in [("Syntax", \EditorWorkspace.mainSyntaxMenu),
                                 ("Indentation", \EditorWorkspace.mainIndentationMenu),
                                 ("Line Endings", \EditorWorkspace.mainLineEndingMenu)] {
            let submenu = NSMenu(title: title)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            view.addItem(item)
            self[keyPath: keyPath] = submenu
        }
        item(view, "Indent", #selector(indentSelection), "]")
        item(view, "Unindent", #selector(unindentSelection), "[")
        item(view, "Split Editor", #selector(toggleSplit), "2", [.command, .option])
        view.addItem(.separator())
        item(view, "Toggle Markdown Preview", #selector(toggleMarkdownPreview), "v", [.command, .shift])
        item(view, "Markdown Preview to the Side", #selector(markdownToSide), "v", [.command, .option])
        item(view, "Markdown Outline…", #selector(showMarkdownOutline))
        item(view, "Export Markdown as HTML…", #selector(exportMarkdown))
        view.addItem(.separator())
        item(view, "Toggle Sidebar", #selector(toggleSidebar), "b", [.command, .control])
        item(view, "Toggle Output", #selector(toggleOutput))
        item(view, "Next Tab", #selector(nextTab), "]", [.command, .shift])
        item(view, "Previous Tab", #selector(previousTab), "[", [.command, .shift])
        let tools = menu("Tools")
        let notes = menu("Notes")
        for template in NoteTemplate.allCases {
            notes.addItem(actionItem("New " + template.title) { [weak self] in self?.newNote(template) })
        }
        notes.addItem(.separator())
        item(notes, "Toggle Task", #selector(toggleNoteTask), "\r", [.command, .shift])
        item(notes, "Bold", #selector(noteBold), "b", [.command, .shift])
        item(notes, "Italic", #selector(noteItalic), "i")
        item(notes, "Inline Code", #selector(noteCode))
        item(notes, "Code Block", #selector(noteCodeBlock))
        item(notes, "Link", #selector(noteLink))
        item(notes, "Insert Date and Time", #selector(insertTimestamp))
        item(tools, "Run Build", #selector(runBuildAction), "b")
        item(tools, "Cancel Build", #selector(cancelBuild), ".", [.command, .control])
        item(tools, "Choose Build Configuration…", #selector(chooseBuild))
        tools.addItem(.separator())
        item(tools, "Run Plugin…", #selector(runPluginAction))
        item(tools, "Choose Plugin…", #selector(choosePlugin))
        item(tools, "Choose Python Interpreter…", #selector(choosePython))
        let preferences = menu("Preferences")
        let themes = NSMenu(title: "Theme")
        themes.autoenablesItems = false
        let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        themeItem.submenu = themes
        preferences.addItem(themeItem)
        for (title, value) in [("Dark", "dark"), ("Light", "light")] {
            themes.addItem(actionItem(title, checked: (configuration?.theme ?? "dark") == value) { [weak self] in self?.setTheme(value) })
        }
        item(preferences, "Load Settings…", #selector(loadConfiguration))
        item(preferences, "Save Settings…", #selector(saveConfiguration))
        item(preferences, "Reset Settings", #selector(resetConfiguration))
        let windowMenu = menu("Window")
        let minimize = NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(minimize)
        item(windowMenu, "Merge All Windows", #selector(mergeWindows))
        windowMenu.addItem(NSMenuItem(title: "Move Window Tab to New Window", action: #selector(NSWindow.moveTabToNewWindow(_:)), keyEquivalent: ""))
        windowMenu.addItem(NSMenuItem(title: "Show Next Window Tab", action: #selector(NSWindow.selectNextTab(_:)), keyEquivalent: ""))
        windowMenu.addItem(NSMenuItem(title: "Show Previous Window Tab", action: #selector(NSWindow.selectPreviousTab(_:)), keyEquivalent: ""))
        self.windowMenu = windowMenu
        if window == nil || window.isKeyWindow { NSApp.mainMenu = main; NSApp.windowsMenu = windowMenu }
        statusMenuSignature = ""
    }

    private func makeWindow() {
        // macOS 14 changes NSView's default clipping to false. These containers
        // own bounded panes; ruler/divider drawing must stay inside their frames.
        for view in [projectSplit, workSplit, editorSplit, contentSplit] { view.clipsToBounds = true }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 810),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Source Editor"
        window.minSize = NSSize(width: 760, height: 420)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.tabbingIdentifier = "SourceEditor.Workspace"
        window.tabbingMode = .automatic
        window.backgroundColor = EditorTheme.background
        window.titlebarAppearsTransparent = true
        window.center()
        window.setFrameAutosaveName("SourceEditor.Main")
        let content = NSView()
        window.contentView = content
        projectSplit.isVertical = true
        projectSplit.dividerStyle = .thin
        projectSplit.useFraction(0.2)
        projectSplit.translatesAutoresizingMaskIntoConstraints = false
        let sidebar = FrameLayoutView()
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = EditorTheme.panel.cgColor
        projectLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        projectLabel.textColor = EditorTheme.muted
        projectLabel.lineBreakMode = .byTruncatingMiddle
        sidebar.addSubview(projectLabel)
        let projectColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("files"))
        projectColumn.width = 240
        projectColumn.resizingMask = []
        projectColumn.minWidth = 1
        outline.addTableColumn(projectColumn)
        outline.style = .plain
        outline.intercellSpacing = NSSize(width: 0, height: 2)
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        outline.frame = NSRect(x: 0, y: 0, width: 240, height: 400)
        outline.autoresizingMask = []
        outline.outlineTableColumn = outline.tableColumns.first
        outline.headerView = nil
        outline.rowHeight = 28
        outline.backgroundColor = EditorTheme.panel
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(projectDoubleClick)
        outline.makeContextMenu = { [weak self] row in self?.sidebarContextMenu(row: row) }
        let projectScroll = SingleColumnScrollView()
        projectScroll.documentView = outline
        projectScroll.hasVerticalScroller = true
        projectScroll.drawsBackground = false
        sidebar.addSubview(projectScroll)
        sidebar.arrange = { [weak self, weak projectScroll] size in
            guard let self, let projectScroll else { return }
            self.projectLabel.frame = NSRect(x: 16, y: 15, width: max(1, size.width - 26), height: 15)
            let frame = NSRect(x: 0, y: 42, width: size.width, height: max(1, size.height - 42))
            if projectScroll.frame != frame { projectScroll.frame = frame; projectScroll.needsLayout = true }
        }
        editorArea = FrameLayoutView()
        editorArea.clipsToBounds = true
        let tabScroll = NSScrollView()
        tabScroll.hasHorizontalScroller = true
        tabScroll.autohidesScrollers = true
        tabScroll.drawsBackground = false
        tabs.orientation = .horizontal
        tabs.alignment = .centerY
        tabs.spacing = 2
        tabs.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        tabScroll.documentView = tabs
        tabs.translatesAutoresizingMaskIntoConstraints = false
        editorSplit.isVertical = true
        editorSplit.dividerStyle = .thin
        contentSplit.isVertical = true
        contentSplit.dividerStyle = .thin
        contentSplit.useFraction(0.5)
        contentSplit.addArrangedSubview(editorSplit)
        workSplit.isVertical = false
        workSplit.dividerStyle = .thin
        workSplit.useFraction(0.72)
        workSplit.addArrangedSubview(contentSplit)
        makeOutputArea()
        workSplit.addArrangedSubview(outputArea)
        outputArea.isHidden = true
        status.style(foreground: EditorTheme.muted, background: EditorTheme.panel)
        makeMarkdownBar()
        makeFindBar()
        noticeBar.orientation = .horizontal
        noticeBar.spacing = 8
        noticeBar.isHidden = true
        noticeLabel.font = NSFont.systemFont(ofSize: 11)
        noticeLabel.lineBreakMode = .byTruncatingTail
        noticeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        noticeButton.target = self; noticeButton.action = #selector(performNoticeAction)
        let dismiss = NSButton(title: "×", target: self, action: #selector(dismissNotice))
        for view in [noticeLabel, noticeButton, dismiss] { noticeBar.addArrangedSubview(view) }
        for view in [tabScroll, noticeBar, markdownBar, findBar, workSplit, status] {
            view.translatesAutoresizingMaskIntoConstraints = true
            view.autoresizingMask = []
            editorArea.addSubview(view)
        }
        editorArea.arrange = { [weak self, weak tabScroll] size in
            guard let self, let tabScroll else { return }
            tabScroll.frame = NSRect(x: 0, y: 0, width: size.width, height: 40)
            let noticeHeight: CGFloat = self.noticeBar.isHidden ? 0 : 28
            self.noticeBar.frame = NSRect(x: 10, y: 40, width: max(1, size.width - 20), height: noticeHeight)
            let markdownHeight: CGFloat = self.markdownBar.isHidden ? 0 : 34
            self.markdownBar.frame = NSRect(x: 10, y: 40 + noticeHeight, width: max(1, size.width - 20), height: markdownHeight)
            let searchHeight: CGFloat = self.findBar.isHidden ? 0 : self.replaceRow.isHidden ? 32 : 66
            self.findBar.frame = NSRect(x: 10, y: 42 + noticeHeight + markdownHeight, width: max(1, size.width - 20), height: searchHeight)
            let top = 44 + noticeHeight + markdownHeight + searchHeight
            let footer: CGFloat = 31
            let workFrame = NSRect(x: 0, y: top, width: size.width, height: max(1, size.height - top - footer))
            if self.workSplit.frame != workFrame { self.workSplit.frame = workFrame; self.workSplit.needsLayout = true }
            self.status.frame = NSRect(x: 0, y: max(0, size.height - 29), width: size.width, height: 29)
        }
        projectSplit.addArrangedSubview(sidebar)
        projectSplit.addArrangedSubview(editorArea)
        content.addSubview(projectSplit)
        NSLayoutConstraint.activate([
            projectSplit.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            projectSplit.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            projectSplit.topAnchor.constraint(equalTo: content.topAnchor),
            projectSplit.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        projectSplit.setPosition(240, ofDividerAt: 0)
    }

    private func makeFindBar() {
        findBar.orientation = .vertical
        findBar.spacing = 6
        findBar.alignment = .leading
        findBar.isHidden = true
        let findRow = NSStackView()
        findRow.orientation = .horizontal
        findRow.spacing = 6
        findRow.alignment = .centerY
        replaceRow.orientation = .horizontal
        replaceRow.spacing = 6
        replaceRow.alignment = .centerY
        replaceRow.isHidden = true
        findField.placeholderString = "Find in current file"
        findField.delegate = self
        findField.sendsSearchStringImmediately = true
        findField.target = self
        findField.action = #selector(findNext)
        replaceField.placeholderString = "Replace with"
        regexToggle.toolTip = "Use regular expressions"
        caseToggle.toolTip = "Match case"
        regexToggle.target = self
        regexToggle.action = #selector(searchOptionsChanged)
        caseToggle.target = self
        caseToggle.action = #selector(searchOptionsChanged)
        findMessage.font = NSFont.systemFont(ofSize: 11)
        findMessage.textColor = EditorTheme.muted
        let next = NSButton(title: "↓", target: self, action: #selector(findNext))
        let previous = NSButton(title: "↑", target: self, action: #selector(findPrevious))
        let replace = NSButton(title: "Replace", target: self, action: #selector(replaceOne))
        let replaceAll = NSButton(title: "All", target: self, action: #selector(replaceAll))
        let close = NSButton(title: "×", target: self, action: #selector(hideFind))
        for view in [findField, regexToggle, caseToggle, previous, next, findMessage, close] { findRow.addArrangedSubview(view) }
        for view in [replaceField, replace, replaceAll] { replaceRow.addArrangedSubview(view) }
        findBar.addArrangedSubview(findRow)
        findBar.addArrangedSubview(replaceRow)
        findRow.widthAnchor.constraint(equalTo: findBar.widthAnchor).isActive = true
        replaceRow.widthAnchor.constraint(equalTo: findBar.widthAnchor).isActive = true
        findField.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        replaceField.widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        findField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        replaceField.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    private func makeOutputArea() {
        outputArea.wantsLayer = true
        outputArea.layer?.backgroundColor = EditorTheme.panel.cgColor
        outputTitle.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        outputTitle.textColor = EditorTheme.muted
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearOutput))
        let close = NSButton(title: "×", target: self, action: #selector(toggleOutput))
        let header = NSStackView(views: [outputTitle, NSView(), clear, close])
        header.orientation = .horizontal
        header.spacing = 8
        outputView.isEditable = false
        outputView.isSelectable = true
        outputView.isRichText = false
        outputView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        outputView.backgroundColor = EditorTheme.background
        outputView.textColor = EditorTheme.foreground
        outputView.textContainerInset = NSSize(width: 12, height: 8)
        outputView.isVerticallyResizable = true
        outputView.isHorizontallyResizable = false
        outputView.autoresizingMask = []
        outputView.frame = NSRect(x: 0, y: 0, width: 640, height: 180)
        outputView.textContainer?.widthTracksTextView = true
        let scroll = EditorScrollView()
        scroll.documentView = outputView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        for view in [header, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = true
            view.autoresizingMask = []
            outputArea.addSubview(view)
        }
        outputArea.arrange = { [weak header, weak scroll] size in
            header?.frame = NSRect(x: 12, y: 4, width: max(1, size.width - 20), height: 28)
            let viewport = NSRect(x: 0, y: 36, width: size.width, height: max(1, size.height - 36))
            if scroll?.frame != viewport { scroll?.frame = viewport; scroll?.needsLayout = true }
        }
    }

    private func showOutput(title: String) {
        outputTitle.stringValue = title
        if outputArea.isHidden {
            outputArea.isHidden = false
            workSplit.adjustSubviews()
            workSplit.setPosition(max(120, workSplit.bounds.height - 200), ofDividerAt: 0)
        }
    }

    private func appendOutput(_ value: String) {
        let storage = outputView.textStorage!
        storage.append(NSAttributedString(string: value, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: EditorTheme.foreground,
        ]))
        let limit = 2_000_000
        if storage.length > limit {
            let remove = NSRange(location: 0, length: storage.length - limit)
            storage.deleteCharacters(in: remove)
            outputWasTrimmed = true
            let log = isPluginRunning ? pluginRunner?.logURL : buildRunner.logURL
            outputTitle.toolTip = "Output view retains the latest 2 million UTF-16 units. Full log: \(log?.path ?? "not available")"
        }
        outputView.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
    }

    @objc private func clearOutput() { outputView.string = ""; outputWasTrimmed = false }
    @objc private func toggleOutput() {
        outputArea.isHidden.toggle()
        workSplit.adjustSubviews()
        if !outputArea.isHidden { workSplit.setPosition(max(120, workSplit.bounds.height - 200), ofDividerAt: 0) }
    }

    @objc private func chooseBuild() {
        let panel = NSOpenPanel()
        panel.title = "Choose Build Configuration"
        panel.message = "Select a JSON build definition. Run Build executes its command locally."
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json] + [UTType(filenameExtension: "sublime-build")].compactMap { $0 }
        if let url = chooseFiles(panel)?.first {
            do {
                buildSpec = try BuildSpec.load(url)
                buildSpecURL = url
                showOutput(title: "BUILD · \(url.lastPathComponent)")
                appendOutput("Selected build: \(url.path)\n")
            } catch { showError(error) }
        }
    }

    @objc private func runBuildAction() {
        if currentDocument?.syntaxIdentifier == "md" {
            setMarkdownMode(.preview)
            return
        }
        if buildSpec == nil { chooseBuild() }
        guard let buildSpec else { return }
        if let document = currentDocument, document.fileURL != nil, document.isModified,
           !save(document) { return }
        runBuild(spec: buildSpec)
    }

    func runBuild(spec: BuildSpec) {
        guard !isBuildRunning else { showOutput(title: "BUILD · RUNNING"); return }
        showOutput(title: "BUILD · RUNNING")
        appendOutput("\n── Build started ──\n")
        isBuildRunning = true
        updateStatus()
        do {
            try buildRunner.start(spec: spec, documentURL: currentDocument?.fileURL,
                projectURL: projectRoot?.url, onOutput: { [weak self] chunk in
                    DispatchQueue.main.async { self?.appendOutput(chunk) }
                }, onCompletion: { [weak self] code in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.isBuildRunning = false
                        self.outputTitle.stringValue = "BUILD · EXIT \(code)"
                        self.appendOutput("\n── Build finished (exit \(code)) ──\n")
                        if let logURL = self.buildRunner.logURL { self.appendOutput("Full build log: \(logURL.path)\n") }
                        self.updateStatus()
                        self.finishPendingClose()
                    }
                })
            if let logURL = buildRunner.logURL { appendOutput("Full build log: \(logURL.path)\n") }
        } catch {
            isBuildRunning = false
            outputTitle.stringValue = "BUILD · FAILED TO START"
            appendOutput(error.localizedDescription + "\n")
            updateStatus()
            showError(error)
        }
    }

    @objc private func cancelBuild() {
        guard isBuildRunning else { return }
        buildRunner.cancel()
        outputTitle.stringValue = "BUILD · CANCELLING"
        appendOutput("\nCancellation requested.\n")
    }

    @objc private func choosePlugin() {
        let panel = NSOpenPanel()
        panel.title = "Choose Python Plugin"
        panel.message = "The selected plugin runs as local Python code with your user account's permissions."
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "py") ?? .plainText]
        if let url = chooseFiles(panel)?.first {
            pluginURL = url
            showOutput(title: "PLUGIN")
            appendOutput("Selected plugin: \(url.path)\n")
        }
    }

    @objc private func choosePython() {
        let panel = NSOpenPanel()
        panel.title = "Choose Python 3 Interpreter"
        panel.message = "Select an installed Python executable."
        panel.canChooseDirectories = false
        if let url = chooseFiles(panel)?.first {
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                showError(EditorFailure.invalidEdit("Selected interpreter is not executable."))
                return
            }
            pythonURL = url
        }
    }

    @objc private func runPluginAction() {
        guard !isPluginRunning else { showOutput(title: "PLUGIN · RUNNING"); return }
        if pluginURL == nil { choosePlugin() }
        guard let pluginURL else { return }
        let alert = NSAlert()
        alert.messageText = "Run Plugin Command"
        alert.informativeText = "\(pluginURL.lastPathComponent)\nEnter the registered command name and optional JSON arguments."
        let command = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 26))
        command.identifier = NSUserInterfaceItemIdentifier("dialog.plugin.command")
        command.placeholderString = "Command name"
        command.stringValue = pluginCommand
        let args = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 26))
        args.identifier = NSUserInterfaceItemIdentifier("dialog.plugin.arguments")
        args.placeholderString = "Arguments (JSON object)"
        args.stringValue = "{}"
        let stack = NSStackView(views: [command, args])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: 60)
        alert.accessoryView = stack
        let runButton = alert.addButton(withTitle: "Run")
        let cancelButton = EditorDialogs.addCancelButton(to: alert)
        configureAlertInputs([command, args], firstResponder: command, submitButton: runButton, alert: alert)
        guard runDialog(alert, cancelButton: cancelButton) == .alertFirstButtonReturn else { return }
        do {
            guard !command.stringValue.isEmpty,
                  let value = try JSONSerialization.jsonObject(with: Data(args.stringValue.utf8)) as? [String: Any] else {
                throw EditorFailure.invalidEdit("Enter a command name and a JSON object for arguments.")
            }
            pluginCommand = command.stringValue
            runPlugin(pythonURL: pythonURL, pluginURL: pluginURL, command: command.stringValue, args: value)
        } catch { showError(error) }
    }

    func runPlugin(pythonURL: URL, pluginURL: URL, command: String, args: [String: Any] = [:]) {
        guard !isPluginRunning, let document = currentDocument, let textView = currentTextView else { return }
        let source = document.storage.string
        let revision = document.revision
        let selections = textView.selectedRanges.map(\.rangeValue)
        isPluginRunning = true
        showOutput(title: "PLUGIN · RUNNING")
        appendOutput("\n── Plugin: \(pluginURL.path) · \(command) ──\n")
        updateStatus()
        pluginRunner = PluginRunner.run(pythonURL: pythonURL, pluginURL: pluginURL, command: command, args: args,
                         text: source, selections: selections) { [weak self, weak document] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isPluginRunning = false
                if let logURL = self.pluginRunner?.logURL { self.appendOutput("Full plugin log: \(logURL.path)\n") }
                self.pluginRunner = nil
                self.outputTitle.stringValue = "PLUGIN · FINISHED"
                switch result {
                case .failure(let error):
                    self.appendOutput("Plugin failed: \(error.localizedDescription)\n")
                    self.outputTitle.stringValue = "PLUGIN · FAILED"
                case .success(let edit):
                    if self.pendingTermination || self.pendingWindowClose {
                        self.appendOutput("Plugin result discarded because the editor is closing.\n")
                    } else if let document, self.documents.contains(where: { $0 === document }), document.revision == revision,
                              document.storage.string.utf16.elementsEqual(source.utf16) {
                        if let error = edit.error { self.appendOutput("Plugin edit rejected: \(error)\n") }
                        else {
                            if self.currentDocument === document { self.replaceText(edit, name: "Plugin: \(command)") }
                            else {
                                document.setTextUndoably(edit.text, actionName: "Plugin: \(command)")
                                self.selectionCache[ObjectIdentifier(document)] = edit.selections.map { NSValue(range: $0) }
                            }
                            self.appendOutput("Plugin command applied.\n")
                        }
                    } else {
                        self.appendOutput("Plugin result was not applied: the document changed or closed while the command was running.\n")
                    }
                }
                self.updateStatus()
                self.finishPendingClose()
            }
        }
    }

    private func finishPendingClose() {
        guard !hasRunningWork else { return }
        if pendingTermination { applicationOwner?.workspaceFinishedWork() }
        else if pendingWindowClose {
            pendingWindowClose = false
            window.close()
        }
    }

    private func freezeForClose() {
        searchDebounce?.cancel(); searchWorker.cancel(); pendingFindAction = nil
        fileMonitor?.stop(); fileMonitor = nil; diskQueue.cancelAllOperations(); diskChecks.removeAll()
        finishRecovery()
        markdownPreview?.stop()
        projectIndexWork?.cancel()
        projectSearchPanel?.close()
        for pane in panes { pane.textView.isEditable = false }
        window.makeFirstResponder(nil)
        updateStatus()
    }

    @objc private func loadConfiguration() {
        let panel = NSOpenPanel()
        panel.title = "Load Editor Configuration"
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        panel.allowedContentTypes += [UTType(filenameExtension: "sublime-settings")].compactMap { $0 }
        if let url = chooseFiles(panel)?.first {
            do { applyConfiguration(try EditorConfiguration.load(url)) }
            catch { showError(error) }
        }
    }

    func applyConfiguration(_ configuration: EditorConfiguration) {
        if let applicationOwner { applicationOwner.applyConfiguration(configuration, updateDocumentSettings: true) }
        else { applyLocalConfiguration(configuration, updateDocumentSettings: true) }
    }

    func applyLocalConfiguration(_ configuration: EditorConfiguration, updateDocumentSettings: Bool) {
        self.configuration = configuration
        for document in documents where updateDocumentSettings {
            var settings = document.settings
            settings.tabSize = configuration.tabSize
            settings.translateTabsToSpaces = configuration.translateTabsToSpaces
            settings.detectIndentation = configuration.detectIndentation
            settings.useTabStops = configuration.useTabStops
            settings.autoIndent = configuration.autoIndent
            settings.smartIndent = configuration.smartIndent
            settings.shiftTabUnindent = configuration.shiftTabUnindent
            do { try document.updateSettings(settings) }
            catch { showError(error) }
        }
        applyTheme(configuration.theme)
        for pane in panes { pane.applyConfiguration(configuration) }
        rebuildTabs()
        outline.reloadData()
        makeMenus()
        applyKeyBindings(configuration.keyBindings)
        updateStatus()
    }

    private func applyTheme(_ theme: String) {
        EditorTheme.isLight = theme == "light"
        NSApp.appearance = NSAppearance(named: EditorTheme.isLight ? .aqua : .darkAqua)
        window.backgroundColor = EditorTheme.background
        outline.backgroundColor = EditorTheme.panel
        projectSplit.arrangedSubviews.first?.layer?.backgroundColor = EditorTheme.panel.cgColor
        projectLabel.textColor = EditorTheme.muted
        status.style(foreground: EditorTheme.muted, background: EditorTheme.panel)
        outputView.backgroundColor = EditorTheme.background
        outputView.textColor = EditorTheme.foreground
        outputTitle.textColor = EditorTheme.muted
        outputArea.layer?.backgroundColor = EditorTheme.panel.cgColor
        markdownInfo.textColor = EditorTheme.muted
        palette.updateTheme()
    }

    @objc private func saveConfiguration() {
        let panel = NSSavePanel()
        panel.title = "Save Editor Configuration"
        panel.nameFieldStringValue = "Preferences.sublime-settings"
        panel.allowedContentTypes = [.json] + [UTType(filenameExtension: "sublime-settings")].compactMap { $0 }
        if let url = chooseFiles(panel)?.first {
            do { try (configuration ?? EditorConfiguration()).save(url) }
            catch { showError(error) }
        }
    }

    @objc private func resetConfiguration() { applyConfiguration(EditorConfiguration()) }
    @objc private func increaseFontSize() { changeFontSize(delta: 1) }
    @objc private func decreaseFontSize() { changeFontSize(delta: -1) }
    @objc private func resetFontSize() {
        var config = configuration ?? EditorConfiguration()
        config.fontSize = config.defaultFontSize
        applyPresentationConfiguration(config)
    }

    private func changeFontSize(delta: Double) {
        var config = configuration ?? EditorConfiguration()
        let size = config.fontSize + delta
        guard size.isFinite, size > 0 else { return }
        config.fontSize = size
        applyPresentationConfiguration(config)
    }

    private func applyPresentationConfiguration(_ config: EditorConfiguration) {
        if let applicationOwner { applicationOwner.applyConfiguration(config, updateDocumentSettings: false) }
        else { applyLocalConfiguration(config, updateDocumentSettings: false) }
    }

    private func setTheme(_ theme: String) {
        var config = configuration ?? EditorConfiguration()
        config.theme = theme
        applyPresentationConfiguration(config)
    }

    private func applyKeyBindings(_ bindings: [String: EditorKeyBinding]) {
        let selectors: [String: Selector] = [
            "new_file": #selector(newFile), "new_window": #selector(newWindow), "open": #selector(openFile), "save": #selector(saveFile),
            "save_all": #selector(saveAll), "revert": #selector(revertFile), "reopen_closed_file": #selector(reopenClosedFile),
            "close": #selector(closeTab), "find": #selector(showFind), "quick_open": #selector(quickOpen),
            "command_palette": #selector(showCommands), "split": #selector(toggleSplit),
            "sort_lines": #selector(sortLines), "upper_case": #selector(uppercase), "lower_case": #selector(lowercase),
            "build": #selector(runBuildAction), "cancel_build": #selector(cancelBuild),
            "run_plugin": #selector(runPluginAction), "configure": #selector(loadConfiguration),
            "find_in_project": #selector(findInProject), "markdown_preview": #selector(toggleMarkdownPreview),
            "markdown_side": #selector(markdownToSide), "toggle_comment": #selector(toggleComment),
            "duplicate_lines": #selector(duplicateLines), "delete_lines": #selector(deleteLines),
            "move_lines_up": #selector(moveLinesUp), "move_lines_down": #selector(moveLinesDown),
        ]
        func allItems(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { [$0] + ($0.submenu.map(allItems) ?? []) }
        }
        guard let menu = mainMenu else { return }
        let items = allItems(menu)
        for (command, binding) in bindings {
            guard let selector = selectors[command], let item = items.first(where: { $0.action == selector }) else { continue }
            let key = binding.keyEquivalent
            let modifiers = binding.modifiers
            for other in items where other !== item && other.keyEquivalent.lowercased() == key && other.keyEquivalentModifierMask == modifiers {
                other.keyEquivalent = ""
            }
            item.keyEquivalent = modifiers.contains(.shift) ? key.uppercased() : key
            item.keyEquivalentModifierMask = modifiers
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if pendingTermination || pendingWindowClose { return menuItem.action == #selector(cancelBuild) }
        switch menuItem.action {
        case #selector(cancelBuild): return isBuildRunning
        case #selector(runBuildAction):
            let markdown = currentDocument?.syntaxIdentifier == "md"
            menuItem.title = markdown ? "Render Markdown" : "Run Build"
            return markdown || !isBuildRunning
        case #selector(chooseBuild): return !isBuildRunning
        case #selector(runPluginAction), #selector(choosePlugin), #selector(choosePython): return !isPluginRunning
        case #selector(toggleNoteTask), #selector(noteBold), #selector(noteItalic), #selector(noteCode), #selector(noteCodeBlock), #selector(noteLink):
            return markdownViewMode != .preview && currentDocument?.resolvedSyntax == .markdown && currentTextView?.hasMarkedText() == false
        case #selector(insertTimestamp): return markdownViewMode != .preview && currentTextView?.hasMarkedText() == false
        case #selector(saveAll): return documents.contains(where: \.isModified)
        case #selector(toggleComment): return markdownViewMode != .preview && currentDocument.map { !["txt", "json"].contains($0.syntaxIdentifier) } == true
        case #selector(duplicateLines), #selector(deleteLines), #selector(moveLinesUp), #selector(moveLinesDown): return markdownViewMode != .preview && currentDocument != nil
        case #selector(revertFile): return currentDocument?.fileURL != nil
        case #selector(reopenClosedFile): return !closedFileURLs.isEmpty
        case #selector(findInProject): return projectRoot != nil
        case #selector(toggleMarkdownPreview), #selector(markdownToSide), #selector(showMarkdownOutline): return currentDocument?.syntaxIdentifier == "md"
        case #selector(exportMarkdown): return currentDocument?.syntaxIdentifier == "md" && markdownPreview?.page != nil && markdownPreview?.isRendering == false
        case #selector(copyFilePath), #selector(copyFileName), #selector(revealCurrentFile): return currentDocument?.fileURL != nil
        case #selector(copyRelativeFilePath): return FilePathFormat.relative.string(for: currentDocument?.fileURL, project: projectRoot?.url) != nil
        case #selector(revealCurrentFileInSidebar): return canRevealInSidebar(currentDocument?.fileURL)
        default: return true
        }
    }

    private func addDocument(_ document: EditorDocument) {
        documents.append(document)
        selectDocument(documents.count - 1)
        refreshFileMonitor()
        if projectRoot == nil { outline.reloadData() }
    }

    func openDocument(_ url: URL) {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        if let index = documents.firstIndex(where: { $0.fileURL?.standardizedFileURL == url }) {
            selectDocument(index)
            noteRecentFile(url)
            return
        }
        do {
            let document = try EditorDocument.open(url, settings: documentDefaults)
            addDocument(document)
            if let fileURL = document.fileURL { noteRecentFile(fileURL) }
        }
        catch { showError(error) }
    }

    func selectDocument(_ index: Int) {
        guard documents.indices.contains(index) else { return }
        if let document = currentDocument, let text = currentTextView {
            selectionCache[ObjectIdentifier(document)] = text.selectedRanges
        }
        selectedIndex = index
        activePane = 0
        rebuildPanes()
        rebuildTabs()
        updateStatus()
        window.makeFirstResponder(currentTextView)
    }

    private func rebuildPanes() {
        for view in editorSplit.arrangedSubviews { editorSplit.removeArrangedSubview(view); view.removeFromSuperview() }
        panes.removeAll()
        guard let document = currentDocument else { return }
        for index in 0..<(splitEnabled ? 2 : 1) {
            let pane = EditorPane(document: document, delegate: self) { [weak self] in
                self?.activePane = index
                self?.updateStatus()
            }
            if let ranges = selectionCache[ObjectIdentifier(document)] {
                let source = document.storage.string
                let length = (source as NSString).length
                let valid = ranges.filter { value in
                    let range = value.rangeValue
                    return range.location >= 0 && range.length >= 0 && range.location <= length &&
                        range.length <= length - range.location && Range(range, in: source) != nil
                }
                pane.textView.selectedRanges = valid.isEmpty ? [NSValue(range: NSRange(location: 0, length: 0))] : valid
            }
            pane.textView.makeContextMenu = { [weak self, weak text = pane.textView] in
                guard let text else { return nil }
                return self?.editorContextMenu(text)
            }
            pane.textView.onPasteImage = { [weak self] data in self?.insertNoteImage(data) }
            panes.append(pane)
            pane.applyConfiguration(configuration ?? EditorConfiguration())
            editorSplit.addArrangedSubview(pane.scroll)
        }
        editorSplit.adjustSubviews()
        editorSplit.useFraction(0.5)
    }

    private func rebuildTabs() {
        for view in tabs.arrangedSubviews { tabs.removeArrangedSubview(view); view.removeFromSuperview() }
        for (index, document) in documents.enumerated() {
            let stack = NSStackView()
            stack.orientation = .horizontal
            stack.spacing = 2
            stack.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 4)
            stack.wantsLayer = true
            stack.layer?.cornerRadius = 5
            stack.layer?.backgroundColor = (index == selectedIndex ? EditorTheme.panel : EditorTheme.background).cgColor
            let button = ContextMenuButton(title: (document.isModified ? "● " : "") + document.displayName,
                                  target: self, action: #selector(tabClicked))
            button.tag = index
            button.isBordered = false
            button.font = NSFont.systemFont(ofSize: 12, weight: index == selectedIndex ? .semibold : .regular)
            button.contentTintColor = index == selectedIndex ? EditorTheme.foreground : EditorTheme.muted
            button.toolTip = document.fileURL?.path ?? "Unsaved document"
            button.makeContextMenu = { [weak self, weak document] in
                guard let document else { return nil }
                return self?.documentContextMenu(document)
            }
            let close = NSButton(title: "×", target: self, action: #selector(tabCloseClicked))
            close.tag = index
            close.isBordered = false
            close.contentTintColor = EditorTheme.muted
            stack.addArrangedSubview(button)
            stack.addArrangedSubview(close)
            tabs.addArrangedSubview(stack)
        }
        tabs.layoutSubtreeIfNeeded()
        tabs.setFrameSize(NSSize(width: max(100, tabs.fittingSize.width), height: 40))
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView,
              let pane = panes.first(where: { $0.textView === textView }) else { return }
        pane.document.markChanged()
    }

    @objc private func documentChanged(_ notification: Notification) {
        guard let document = notification.object as? EditorDocument,
              documents.contains(where: { $0 === document }) else { return }
        for pane in panes where pane.document === document { pane.scheduleHighlight() }
        updateTab(document)
        updateStatus()
        updateFindCount()
    }

    private func updateTab(_ document: EditorDocument) {
        guard let index = documents.firstIndex(where: { $0 === document }),
              tabs.arrangedSubviews.indices.contains(index),
              let stack = tabs.arrangedSubviews[index] as? NSStackView,
              let button = stack.arrangedSubviews.first as? ContextMenuButton else { return }
        let title = (document.isModified ? "● " : "") + document.displayName
        button.toolTip = document.fileURL?.path ?? "Unsaved document"
        guard button.title != title else { return }
        button.title = title
        tabs.layoutSubtreeIfNeeded()
        tabs.setFrameSize(NSSize(width: max(100, tabs.fittingSize.width), height: 40))
    }

    func textViewDidChangeSelection(_ notification: Notification) { updateStatus() }

    func undoManager(for view: NSTextView) -> UndoManager? {
        panes.first(where: { $0.textView === view })?.document.undoManager
    }

    private func updateStatus() {
        guard let document = currentDocument, let textView = currentTextView else { return }
        let source = document.storage.string as NSString
        let selection = textView.selectedRange()
        let offset = min(selection.location, source.length)
        let position = document.position(at: offset)
        let selectedCharacters = selection.length > 0 && NSMaxRange(selection) <= source.length ? source.substring(with: selection).count : 0
        let selectionText = textView.selectedRanges.count > 1 ? "  •  \(textView.selectedRanges.count) cursors" :
            selectedCharacters > 0 ? "  •  \(selectedCharacters) characters selected" : ""
        status.location.stringValue = position.map { "Ln \($0.line), Col \($0.column)\(selectionText)" } ?? "Position unknown\(selectionText)"
        let activity = isBuildRunning ? "    Building…" : isPluginRunning ? "    Plugin running…" : ""
        status.location.stringValue += activity
        updateDocumentMenus()
        window.title = "\(document.displayName)\(document.isModified ? " •" : "") — Source Editor"
        window.isDocumentEdited = document.isModified
        window.representedURL = document.fileURL
        refreshMarkdown()
    }

    @objc private func performMenuAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? EditorMenuAction else { return }
        action.run()
        #if EDITOR_TESTS
        lastMenuActionID = String(describing: ObjectIdentifier(action))
        menuActionCount += 1
        #endif
        window.makeFirstResponder(currentTextView)
    }

    private func actionItem(_ title: String, checked: Bool = false, enabled: Bool = true,
                            run: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(performMenuAction(_:)), keyEquivalent: "")
        item.target = self
        item.state = checked ? .on : .off
        item.isEnabled = enabled
        item.representedObject = EditorMenuAction(run)
        return item
    }

    private func fillEncodingMenu(_ menu: NSMenu, reopen: Bool, saveImmediately: Bool = false) {
        menu.autoenablesItems = false
        menu.removeAllItems()
        for encoding in EditorEncoding.allCases where encoding.isShippedTextEncoding && (saveImmediately || !encoding.hasBOM) {
            menu.addItem(actionItem(encoding.displayName, checked: currentDocument?.encoding == encoding,
                                   enabled: !reopen || currentDocument?.fileURL != nil) { [weak self] in
                guard let self, let document = self.currentDocument else { return }
                do {
                    if reopen {
                        guard self.confirmClose(document) else { return }
                        try document.reopen(using: encoding, discardChanges: true)
                        self.resetSelectionsAfterReload(document)
                    } else {
                        try document.setEncoding(encoding)
                        if saveImmediately { self.save(document) }
                    }
                    self.updateStatus()
                } catch { self.showError(error) }
            })
        }
    }

    private func fillIndentationMenu(_ menu: NSMenu) {
        menu.autoenablesItems = false
        menu.removeAllItems()
        guard let document = currentDocument else { return }
        menu.addItem(actionItem("Indent Using Spaces", checked: document.settings.translateTabsToSpaces) { [weak self] in
            self?.changeDocumentSettings { $0.translateTabsToSpaces.toggle() }
        })
        menu.addItem(.separator())
        for size in 1...8 {
            menu.addItem(actionItem("Tab Width: \(size)", checked: document.settings.tabSize == size) { [weak self] in
                self?.changeDocumentSettings { $0.tabSize = size }
            })
        }
        menu.addItem(actionItem("Other Tab Width…", checked: document.settings.tabSize > 8) { [weak self] in self?.chooseTabWidth() })
        menu.addItem(.separator())
        menu.addItem(actionItem("Guess Settings From Buffer") { [weak self] in
            guard let self, let document = self.currentDocument else { return }
            do { try document.detectIndentation(); self.refreshDocumentPresentation() }
            catch { self.showError(error) }
        })
        menu.addItem(actionItem("Convert Indentation to Spaces") { [weak self] in self?.convertIndentation(toSpaces: true) })
        menu.addItem(actionItem("Convert Indentation to Tabs") { [weak self] in self?.convertIndentation(toSpaces: false) })
    }

    private func fillLineEndingMenu(_ menu: NSMenu, statusPopup: Bool) {
        menu.autoenablesItems = false
        menu.removeAllItems()
        let choices: [(LineEnding, String, String)] = [
            (.crlf, "Windows", "Windows Line Endings (CRLF)"),
            (.lf, "Unix", "Unix Line Endings (LF)"),
            (.cr, "Mac OS 9", "Mac OS 9 Line Endings (CR)")]
        for (ending, mainTitle, popupTitle) in choices {
            menu.addItem(actionItem(statusPopup ? popupTitle : mainTitle,
                                   checked: currentDocument?.settings.lineEnding == ending) { [weak self] in
                guard let self, let document = self.currentDocument, let text = self.currentTextView else { return }
                let result = document.convertLineEndings(to: ending, selections: text.selectedRanges.map(\.rangeValue))
                if let error = result.error { self.showError(EditorFailure.invalidEdit(error)); return }
                text.selectedRanges = result.selections.map { NSValue(range: $0) }
                self.updateStatus()
            })
        }
    }

    private func fillSyntaxMenu(_ menu: NSMenu) {
        menu.autoenablesItems = false
        menu.removeAllItems()
        for syntax in EditorSyntax.allCases {
            menu.addItem(actionItem(syntax.displayName, checked: currentDocument?.syntaxIdentifier == syntax.rawValue) { [weak self] in
                self?.changeDocumentSettings { $0.syntax = syntax.rawValue }
            })
        }
    }

    private func updateDocumentMenus() {
        guard let document = currentDocument else { return }
        let settings = document.settings
        let signature = "\(ObjectIdentifier(document))|\(document.encoding.rawValue)|\(settings.lineEnding.rawValue)|\(settings.tabSize)|\(settings.translateTabsToSpaces)|\(document.syntaxIdentifier)|\(document.fileURL?.path ?? "")"
        guard signature != statusMenuSignature else { return }
        statusMenuSignature = signature
        let encodingMenu = NSMenu(title: "Encoding")
        encodingMenu.autoenablesItems = false
        for (title, reopen) in [("Set Encoding", false), ("Reopen with Encoding", true)] {
            let submenu = NSMenu(title: title)
            fillEncodingMenu(submenu, reopen: reopen)
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            parent.submenu = submenu
            encodingMenu.addItem(parent)
        }
        status.setMenu(encodingMenu, title: document.encodingDescription, for: status.encoding)
        let endingMenu = NSMenu(title: "Line Endings")
        fillLineEndingMenu(endingMenu, statusPopup: true)
        let endingTitle = settings.lineEnding == .crlf ? "CRLF" : settings.lineEnding == .cr ? "CR" : "LF"
        status.setMenu(endingMenu, title: endingTitle, for: status.lineEnding)
        let indentMenu = NSMenu(title: "Indentation")
        fillIndentationMenu(indentMenu)
        status.setMenu(indentMenu, title: "\(settings.translateTabsToSpaces ? "Spaces" : "Tab Size"): \(settings.tabSize)", for: status.indentation)
        let syntaxMenu = NSMenu(title: "Syntax")
        fillSyntaxMenu(syntaxMenu)
        status.setMenu(syntaxMenu, title: document.syntaxDisplayName, for: status.syntax)
        if let saveEncodingMenu { fillEncodingMenu(saveEncodingMenu, reopen: false, saveImmediately: true) }
        if let reopenEncodingMenu { fillEncodingMenu(reopenEncodingMenu, reopen: true) }
        if let mainIndentationMenu { fillIndentationMenu(mainIndentationMenu) }
        if let mainLineEndingMenu { fillLineEndingMenu(mainLineEndingMenu, statusPopup: false) }
        if let mainSyntaxMenu { fillSyntaxMenu(mainSyntaxMenu) }
    }

    private func changeDocumentSettings(_ change: (inout DocumentSettings) -> Void) {
        guard let document = currentDocument else { return }
        var settings = document.settings
        change(&settings)
        do { try document.updateSettings(settings); refreshDocumentPresentation() }
        catch { showError(error) }
    }

    private func configureAlertInputs(_ fields: [NSTextField], firstResponder: NSTextField,
                                      submitButton: NSButton, alert: NSAlert) {
        for field in fields {
            field.target = submitButton
            field.action = #selector(NSButton.performClick(_:))
        }
        alert.window.initialFirstResponder = firstResponder
    }

    private func chooseTabWidth() {
        guard let document = currentDocument else { return }
        let alert = NSAlert()
        alert.messageText = "Tab Width"
        alert.informativeText = "Enter a positive number of columns."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 26))
        field.identifier = NSUserInterfaceItemIdentifier("dialog.tabWidth")
        field.stringValue = String(document.settings.tabSize)
        alert.accessoryView = field
        let setButton = alert.addButton(withTitle: "Set")
        let cancelButton = EditorDialogs.addCancelButton(to: alert)
        configureAlertInputs([field], firstResponder: field, submitButton: setButton, alert: alert)
        guard runDialog(alert, cancelButton: cancelButton) == .alertFirstButtonReturn else { return }
        guard let width = Int(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            showError(EditorFailure.invalidEdit("Tab width must be a positive integer."))
            return
        }
        changeDocumentSettings { $0.tabSize = width }
    }

    private func refreshDocumentPresentation() {
        for pane in panes {
            if let configuration { pane.applyConfiguration(configuration) }
            else { pane.applyConfiguration(EditorConfiguration()) }
            pane.scheduleHighlight()
        }
        updateStatus()
    }

    @objc private func indentSelection() { indent(outdent: false) }
    @objc private func duplicateLines() { editLines(.duplicate, name: "Duplicate Lines") }
    @objc private func deleteLines() { editLines(.delete, name: "Delete Lines") }
    @objc private func moveLinesUp() { editLines(.moveUp, name: "Move Lines Up") }
    @objc private func moveLinesDown() { editLines(.moveDown, name: "Move Lines Down") }
    private func editLines(_ action: LineEditAction, name: String) {
        guard markdownViewMode != .preview, let view = currentTextView as? EditorTextView, let document = currentDocument else { return }
        view.applyEditorResult(TextOperations.editLines(in: view.string, selections: view.selectedRanges.map(\.rangeValue),
                                                     action: action, ending: document.settings.lineEnding), name: name)
    }
    @objc private func toggleComment() {
        guard markdownViewMode != .preview, let view = currentTextView as? EditorTextView,
              let document = currentDocument, let syntax = EditorSyntax.resolve(document.syntaxIdentifier) else { return }
        let result = TextOperations.toggleComment(in: view.string, selections: view.selectedRanges.map(\.rangeValue), syntax: syntax)
        if let error = result.error { showError(EditorFailure.invalidEdit(error)); return }
        view.applyEditorResult(result, name: "Toggle Comment")
    }
    @objc private func unindentSelection() { indent(outdent: true) }

    private func indent(outdent: Bool) {
        guard let text = currentTextView as? EditorTextView, let document = currentDocument else { return }
        text.applyEditorResult(TextOperations.indentLines(in: text.string, selections: text.selectedRanges.map(\.rangeValue),
                                                        settings: document.settings, outdent: outdent),
                               name: outdent ? "Unindent" : "Indent")
    }

    private func convertIndentation(toSpaces: Bool) {
        guard let text = currentTextView as? EditorTextView, let document = currentDocument else { return }
        let result = TextOperations.convertIndentation(in: text.string, selections: text.selectedRanges.map(\.rangeValue),
                                                      tabSize: document.settings.tabSize, toSpaces: toSpaces)
        text.applyEditorResult(result, name: toSpaces ? "Convert Indentation to Spaces" : "Convert Indentation to Tabs")
        changeDocumentSettings { $0.translateTabsToSpaces = toSpaces }
    }

    func setProject(_ url: URL) {
        let url = url.absoluteURL.standardizedFileURL.resolvingSymlinksInPath()
        if projectDocument?.folderURL != url { projectDocument = nil }
        projectRoot = ProjectItem(url)
        projectLabel.stringValue = url.lastPathComponent.uppercased()
        projectLabel.toolTip = url.path
        outline.reloadData()
        outline.expandItem(projectRoot)
        projectFiles.removeAll()
        projectIndexWork?.cancel()
        projectIndexGeneration += 1
        let generation = projectIndexGeneration
        let work = ProjectIndexOperation(url)
        work.completionBlock = { [weak self, weak work] in
            guard let work, !work.isCancelled else { return }
            let files = work.files
            let summary = work.summary
            DispatchQueue.main.async { [weak self] in
                guard let self, self.projectIndexGeneration == generation, self.projectRoot?.url == url else { return }
                self.projectFiles = files
                if summary.limited || summary.unreadable > 0 {
                    self.projectLabel.toolTip = url.path + " — Quick Open indexed \(files.count) files; \(summary.unreadable) unreadable folders" + (summary.limited ? "; 50,000 file limit reached" : "")
                }
            }
        }
        projectIndexWork = work
        DispatchQueue.global(qos: .userInitiated).async { work.start() }
        refreshFileMonitor()
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let item = item as? ProjectItem { return item.children.count }
        return projectRoot == nil ? documents.count : 1
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let item = item as? ProjectItem { return item.children[index] }
        if let projectRoot { return projectRoot }
        return documents[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? ProjectItem)?.isDirectory == true
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let value: String
        let path: String?
        let isFolder: Bool
        if let item = item as? ProjectItem {
            value = item.url.lastPathComponent
            path = item.url.path
            isFolder = item.isDirectory
        } else if let document = item as? EditorDocument {
            value = document.displayName
            path = document.fileURL?.path
            isFolder = false
        } else { return nil }
        let cell = NSTableCellView()
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: isFolder ? "folder" : "doc.text", accessibilityDescription: nil)
        icon.contentTintColor = isFolder ? EditorTheme.accent : EditorTheme.muted
        let label = NSTextField(labelWithString: value)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = EditorTheme.foreground
        label.lineBreakMode = .byTruncatingMiddle
        cell.toolTip = path
        for view in [icon, label] { view.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(view) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    @objc private func projectDoubleClick() {
        guard outline.clickedRow >= 0, let item = outline.item(atRow: outline.clickedRow) else { return }
        if let item = item as? ProjectItem {
            if item.isDirectory {
                if outline.isItemExpanded(item) { outline.collapseItem(item) } else { outline.expandItem(item) }
            } else { openDocument(item.url) }
        } else if let document = item as? EditorDocument, let index = documents.firstIndex(where: { $0 === document }) {
            selectDocument(index)
        }
    }

    private var documentDefaults: DocumentSettings {
        let config = configuration ?? EditorConfiguration()
        var settings = DocumentSettings()
        settings.tabSize = config.tabSize
        settings.translateTabsToSpaces = config.translateTabsToSpaces
        settings.detectIndentation = config.detectIndentation
        settings.useTabStops = config.useTabStops
        settings.autoIndent = config.autoIndent
        settings.smartIndent = config.smartIndent
        settings.shiftTabUnindent = config.shiftTabUnindent
        return settings
    }

    @objc private func newFile() { addDocument(EditorDocument(settings: documentDefaults)) }

    @objc private func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if let urls = chooseFiles(panel) { for url in urls { openDocument(url) } }
    }

    @objc private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        if let url = chooseFiles(panel)?.first { setProject(url) }
    }

    @objc private func openProjectFile() {
        let panel = NSOpenPanel()
        panel.title = "Open Project File"
        panel.allowedContentTypes = [.json] + [UTType(filenameExtension: "sublime-project")].compactMap { $0 }
        if let url = chooseFiles(panel)?.first {
            do { openProject(try EditorProject.load(url)) }
            catch { showError(error) }
        }
    }

    func openProject(_ project: EditorProject) {
        projectDocument = project
        setProject(project.folderURL)
    }

    @objc private func saveProjectAs() {
        guard let folder = projectRoot?.url else {
            showError(EditorFailure.invalidEdit("Open a folder before saving a project."))
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = folder.lastPathComponent + ".sublime-project"
        panel.allowedContentTypes = [.json] + [UTType(filenameExtension: "sublime-project")].compactMap { $0 }
        guard let url = chooseFiles(panel)?.first else { return }
        do {
            let project = projectDocument ?? EditorProject(folderURL: folder)
            try project.save(url)
            projectDocument = try EditorProject.load(url)
        } catch { showError(error) }
    }

    var sessionSnapshot: EditorSession {
        if let document = currentDocument, let text = currentTextView {
            selectionCache[ObjectIdentifier(document)] = text.selectedRanges
        }
        return EditorSession(projectPath: projectRoot?.url.path, selectedIndex: selectedIndex, split: splitEnabled,
            documents: documents.map { document in
                EditorSession.Document(document: document,
                    ranges: selectionCache[ObjectIdentifier(document)]?.map(\.rangeValue) ?? [NSRange(location: 0, length: 0)])
            })
    }

    @objc private func toggleAutoRecovery() { setAutoRecovery(recovery == nil) }
    func setAutoRecovery(_ enabled: Bool, directory: URL? = nil) {
        guard !pendingTermination, !pendingWindowClose else { return }
        #if !EDITOR_TESTS
        UserDefaults.standard.set(enabled, forKey: "autoRecovery")
        #endif
        if enabled {
            guard recovery == nil else { return }
            recovery = EditorRecovery(directory: directory ?? EditorRecovery.defaultDirectory)
            recoverySignature = ""
            recoveryMenuItem?.state = .on
            recoveryMessage = "Auto recovery is enabled; snapshots update every 5 seconds"
            recoveryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.updateRecoverySnapshot() }
            updateRecoverySnapshot()
        } else { finishRecovery() }
        status.location.toolTip = recoveryMessage
    }

    private func updateRecoverySnapshot() {
        guard let recovery, !recovery.isWriting, !recovery.isFinishing else { return }
        let modified = documents.filter(\.isModified)
        let signature = modified.map { "\(ObjectIdentifier($0)):\($0.revision):\($0.encoding):\($0.settings)" }.joined(separator: "|")
        guard signature != recoverySignature else { return }
        guard modified.count <= 128, modified.reduce(0, { $0 + $1.storage.length }) <= EditorRecovery.maximumUTF16 else {
            recoveryMessage = "Auto recovery paused: capacity exceeded. Save files or use Save Session. Last snapshot may be older."
            status.location.toolTip = recoveryMessage
            return
        }
        if let document = currentDocument, let view = currentTextView { selectionCache[ObjectIdentifier(document)] = view.selectedRanges }
        let selected = modified.firstIndex(where: { $0 === currentDocument }) ?? 0
        let snapshot = modified.isEmpty ? nil : EditorSession(projectPath: projectRoot?.url.path, selectedIndex: selected, split: splitEnabled,
            documents: modified.map { EditorSession.Document(document: $0, ranges: Array((selectionCache[ObjectIdentifier($0)]?.map(\.rangeValue) ?? []).prefix(4096))) })
        recoverySignature = signature
        recovery.write(snapshot) { [weak self, weak recovery] error in
            guard let self, self.recovery === recovery, !self.pendingWindowClose, !self.pendingTermination else { return }
            if let error { self.recoverySignature = ""; self.recoveryMessage = "Auto recovery failed: " + error.localizedDescription }
            else { self.recoveryMessage = snapshot == nil ? "Auto recovery: all documents saved" : "Auto recovery snapshot updated at " + DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium) }
            self.status.location.toolTip = self.recoveryMessage
        }
    }

    private func finishRecovery() {
        recoveryTimer?.invalidate(); recoveryTimer = nil
        guard let owner = recovery, !owner.isFinishing else { return }
        recoveryMenuItem?.state = .off
        owner.finish { [self, owner] error in
            if recovery === owner { recovery = nil; recoverySignature = "" }
            recoveryMessage = error.map { "Recovery snapshot cleanup failed: " + $0.localizedDescription } ?? "Auto recovery is off"
            status.location.toolTip = recoveryMessage
            finishPendingClose()
        }
    }

    @objc private func recoverSnapshot() {
        let panel = NSOpenPanel()
        panel.title = "Recover Snapshot in New Window"
        panel.message = "Restore unsaved text. A changed or missing original file opens as an untitled recovery buffer."
        panel.directoryURL = EditorRecovery.defaultDirectory
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        guard let url = chooseFiles(panel)?.first else { return }
        do { _ = try restoreRecoverySnapshot(url) } catch { showError(error) }
    }
    @discardableResult
    func restoreRecoverySnapshot(_ url: URL) throws -> EditorWorkspace {
        guard !EditorRecovery.activeURLs.contains(url.standardizedFileURL) else {
            throw EditorFailure.invalidEdit("This snapshot belongs to a live window. Use that window or Save Session instead.")
        }
        let session = try EditorSession.load(url)
        guard let applicationOwner else { throw EditorFailure.invalidEdit("A recovery requires an application workspace owner.") }
        let workspace = applicationOwner.newWindow()
        _ = workspace.restoreSession(session)
        return workspace
    }
    @objc private func revealRecoveryFolder() {
        do {
            try FileManager.default.createDirectory(at: EditorRecovery.defaultDirectory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            NSWorkspace.shared.open(EditorRecovery.defaultDirectory)
        } catch { showError(error) }
    }

    @discardableResult
    func restoreSession(_ session: EditorSession) -> Bool {
        guard !isBuildRunning, !isPluginRunning else {
            showError(EditorFailure.invalidEdit("Wait for the current build or plugin to finish before restoring a session."))
            return false
        }
        for document in documents where document.isModified {
            if !confirmClose(document) { return false }
        }
        let restored = session.documents.map { $0.restore() }
        guard !restored.isEmpty, restored.indices.contains(session.selectedIndex) else { return false }
        // Clear old pane resources before replacing the document owner list.
        for view in editorSplit.arrangedSubviews { editorSplit.removeArrangedSubview(view); view.removeFromSuperview() }
        panes.removeAll()
        documents = restored.map(\.0)
        markdownModeCache.removeAll()
        selectionCache = Dictionary(uniqueKeysWithValues: restored.map { document, ranges in
            (ObjectIdentifier(document), ranges.map { NSValue(range: $0) })
        })
        projectDocument = nil
        projectRoot = nil
        projectFiles = []
        projectIndexWork?.cancel()
        projectLabel.stringValue = "OPEN FILES"
        if let path = session.projectPath {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { setProject(url) }
        }
        splitEnabled = session.split
        // Prevent selectDocument from caching the already-disposed selection over
        // a restored document before it creates the new panes.
        selectedIndex = session.selectedIndex
        activePane = 0
        rebuildPanes()
        rebuildTabs()
        outline.reloadData()
        updateStatus()
        window.makeFirstResponder(currentTextView)
        refreshFileMonitor()
        return true
    }

    @objc private func saveSession() {
        let panel = NSSavePanel()
        panel.title = "Save Session"
        panel.nameFieldStringValue = "workspace.source-session.json"
        panel.allowedContentTypes = [.json]
        if let url = chooseFiles(panel)?.first {
            do { try sessionSnapshot.save(url) }
            catch { showError(error) }
        }
    }

    @objc private func loadSession() {
        let panel = NSOpenPanel()
        panel.title = "Restore Session"
        panel.allowedContentTypes = [.json]
        if let url = chooseFiles(panel)?.first {
            do { restoreSession(try EditorSession.load(url)) }
            catch { showError(error) }
        }
    }

    @discardableResult
    private func save(_ document: EditorDocument, saveAs: Bool = false) -> Bool {
        var target: URL?
        if saveAs || document.fileURL == nil {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = document.displayName == "Untitled" ? "untitled." + (document.resolvedSyntax?.identifier ?? "txt") : document.displayName
            panel.directoryURL = document.fileURL?.deletingLastPathComponent() ?? projectRoot?.url
            guard let url = chooseFiles(panel)?.first else { return false }
            target = url
        }
        do {
            // NSSavePanel already obtains explicit replacement approval for a chosen
            // existing destination. Current-file conflict checks remain in the core.
            try document.save(to: target, allowOverwrite: target != nil)
            diskChanges.removeValue(forKey: ObjectIdentifier(document))
            if diskChanges.isEmpty, noticeKind == "disk" { dismissNotice() }
            if let url = document.fileURL { noteRecentFile(url) }
            refreshFileMonitor()
            rebuildTabs()
            for pane in panes { pane.scheduleHighlight() }
            updateStatus()
            outline.reloadData()
            return true
        } catch {
            showError(error)
            return false
        }
    }

    @objc private func saveFile() { if let document = currentDocument { save(document) } }
    @objc private func saveAs() { if let document = currentDocument { save(document, saveAs: true) } }

    @objc private func saveAll() { _ = saveAllDocuments() }

    @discardableResult
    func saveAllDocuments() -> Bool {
        let selected = currentDocument
        defer {
            if let selected, let index = documents.firstIndex(where: { $0 === selected }), currentDocument !== selected {
                selectDocument(index)
            }
        }
        for document in documents where document.isModified {
            // Associate an untitled save sheet with the tab being saved.
            if document.fileURL == nil, let index = documents.firstIndex(where: { $0 === document }) { selectDocument(index) }
            if !save(document) { return false }
        }
        return true
    }

    @objc private func revertFile() { _ = revertCurrentDocument() }

    @discardableResult
    func revertCurrentDocument() -> Bool {
        guard let document = currentDocument, document.fileURL != nil else { return false }
        if document.isModified {
            let alert = NSAlert()
            alert.messageText = "Revert “\(document.displayName)”?"
            alert.informativeText = "Reload the file from disk. Unsaved text and encoding changes will be discarded."
            let cancelButton = EditorDialogs.addCancelButton(to: alert)
            cancelButton.keyEquivalent = "\r"
            alert.window.defaultButtonCell = cancelButton.cell as? NSButtonCell
            alert.addButton(withTitle: "Revert")
            guard runDialog(alert, cancelButton: cancelButton) == .alertSecondButtonReturn else { return false }
        }
        do {
            try document.reopen(using: document.diskEncoding, discardChanges: true)
            resetSelectionsAfterReload(document)
            rebuildTabs()
            updateStatus()
            return true
        } catch { showError(error); return false }
    }

    private func resetSelectionsAfterReload(_ document: EditorDocument) {
        selectionCache[ObjectIdentifier(document)] = [NSValue(range: NSRange(location: 0, length: 0))]
        for pane in panes where pane.textView.textStorage === document.storage {
            pane.textView.setSelectedRange(NSRange(location: 0, length: 0))
            pane.scheduleHighlight()
        }
    }

    private func noteRecentFile(_ url: URL) {
        recentFiles.note(url)
        refreshRecentFilesMenu()
    }

    private func refreshRecentFilesMenu() {
        guard let menu = recentFilesMenu else { return }
        menu.autoenablesItems = false
        menu.removeAllItems()
        if recentFiles.urls.isEmpty {
            let empty = NSMenuItem(title: "No Recent Files", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for url in recentFiles.urls {
            let directory = url.deletingLastPathComponent().lastPathComponent
            let item = actionItem("\(url.lastPathComponent)  (\(directory))") { [weak self] in self?.openDocument(url) }
            item.toolTip = url.path
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(actionItem("Clear Recent Files", enabled: !recentFiles.urls.isEmpty) { [weak self] in
            self?.recentFiles.clear()
            self?.refreshRecentFilesMenu()
        })
    }

    @objc private func reopenClosedFile() {
        guard let url = closedFileURLs.last else { return }
        openDocument(url)
        if documents.contains(where: { $0.fileURL == url }) { closedFileURLs.removeLast() }
    }

    private func confirmClose(_ document: EditorDocument) -> Bool {
        guard document.isModified else { return true }
        let selected = currentDocument
        if currentDocument !== document, let index = documents.firstIndex(where: { $0 === document }) {
            selectDocument(index)
        }
        defer {
            if let selected, currentDocument !== selected,
               let index = documents.firstIndex(where: { $0 === selected }) { selectDocument(index) }
        }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(document.displayName)”?"
        alert.informativeText = "Your changes will be lost if you close without saving."
        alert.addButton(withTitle: "Save")
        let cancelButton = EditorDialogs.addCancelButton(to: alert)
        alert.addButton(withTitle: "Don't Save")
        switch runDialog(alert, cancelButton: cancelButton) {
        case .alertFirstButtonReturn: return save(document)
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    @discardableResult
    private func closeDocument(_ index: Int) -> Bool {
        guard !pendingTermination, !pendingWindowClose else { return false }
        guard documents.indices.contains(index), confirmClose(documents[index]) else { return false }
        let oldSelected = selectedIndex
        if let url = documents[index].fileURL {
            closedFileURLs.removeAll { $0 == url }
            closedFileURLs.append(url)
            if closedFileURLs.count > 20 { closedFileURLs.removeFirst() }
        }
        selectionCache.removeValue(forKey: ObjectIdentifier(documents[index]))
        markdownModeCache.removeValue(forKey: ObjectIdentifier(documents[index]))
        let closedIdentity = ObjectIdentifier(documents[index])
        documents.remove(at: index)
        diskChecks.removeValue(forKey: closedIdentity)?.cancel()
        diskChanges.removeValue(forKey: closedIdentity)
        refreshFileMonitor()
        if documents.isEmpty { addDocument(EditorDocument(settings: documentDefaults)) }
        else { selectDocument(min(documents.count - 1, index < oldSelected ? oldSelected - 1 : oldSelected)) }
        if projectRoot == nil { outline.reloadData() }
        return true
    }

    @objc private func closeTab() { closeDocument(selectedIndex) }
    @objc private func tabClicked(_ sender: NSButton) { selectDocument(sender.tag) }
    @objc private func tabCloseClicked(_ sender: NSButton) { closeDocument(sender.tag) }
    @objc private func nextTab() { if !documents.isEmpty { selectDocument((selectedIndex + 1) % documents.count) } }
    @objc private func previousTab() { if !documents.isEmpty { selectDocument((selectedIndex + documents.count - 1) % documents.count) } }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Source Editor"
        alert.informativeText = "An independently implemented native text editor.\nAppKit · local files · shared text storage\n\nThis reconstruction implements selected observed editor workflows. It does not contain Sublime Text's native engine or provide complete Sublime compatibility."
        runDialog(alert)
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        runDialog(alert)
    }

    private func copyPath(_ url: URL?, format: FilePathFormat) {
        guard let value = format.string(for: url, project: projectRoot?.url) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    @objc private func copyFilePath() { copyPath(currentDocument?.fileURL, format: .absolute) }
    @objc private func copyRelativeFilePath() { copyPath(currentDocument?.fileURL, format: .relative) }
    @objc private func copyFileName() { copyPath(currentDocument?.fileURL, format: .filename) }
    @objc private func revealCurrentFile() {
        if let url = currentDocument?.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
    @objc private func revealCurrentFileInSidebar() {
        if let url = currentDocument?.fileURL { revealInSidebar(url) }
    }

    private func canRevealInSidebar(_ url: URL?) -> Bool {
        guard let url else { return false }
        if projectRoot == nil { return documents.contains { $0.fileURL == url } }
        return FilePathFormat.relative.string(for: url, project: projectRoot?.url) != nil
    }

    private func revealInSidebar(_ url: URL) {
        guard canRevealInSidebar(url) else { return }
        if projectSplit.arrangedSubviews.first?.isHidden == true { toggleSidebar() }
        var target: Any?
        if let root = projectRoot, let relative = FilePathFormat.relative.string(for: url, project: root.url) {
            var node = root
            if relative != "." {
                for component in relative.split(separator: "/") {
                    outline.expandItem(node)
                    guard let child = node.children.first(where: { $0.url.lastPathComponent == String(component) }) else { return }
                    node = child
                }
            }
            target = node
        } else { target = documents.first { $0.fileURL == url } }
        guard let target else { return }
        let row = outline.row(forItem: target)
        guard row >= 0 else { return }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }

    private func appendPathItems(to menu: NSMenu, url: URL?) {
        for (title, format) in [("Copy File Path", FilePathFormat.absolute), ("Copy Relative File Path", .relative),
                                ("Copy File Name", .filename), ("Copy Folder Path", .directory)] {
            menu.addItem(actionItem(title, enabled: format.string(for: url, project: projectRoot?.url) != nil) { [weak self] in
                self?.copyPath(url, format: format)
            })
        }
        menu.addItem(actionItem("Open Containing Folder…", enabled: url != nil) {
            if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        })
        menu.addItem(actionItem("Reveal in Side Bar", enabled: canRevealInSidebar(url)) { [weak self] in
            if let url { self?.revealInSidebar(url) }
        })
    }

    private func withDocument(_ document: EditorDocument, action: () -> Void) {
        guard let index = documents.firstIndex(where: { $0 === document }) else { return }
        let selected = currentDocument
        if currentDocument !== document { selectDocument(index) }
        defer {
            if let selected, currentDocument !== selected,
               let index = documents.firstIndex(where: { $0 === selected }) { selectDocument(index) }
        }
        action()
    }

    private func closeCandidates(_ scope: TabCloseScope, anchor: EditorDocument) -> [EditorDocument] {
        guard let index = documents.firstIndex(where: { $0 === anchor }) else { return [] }
        switch scope {
        case .others: return documents.filter { $0 !== anchor }
        case .right: return Array(documents.dropFirst(index + 1))
        case .unmodified: return documents.filter { !$0.isModified }
        }
    }

    private func closeDocuments(_ candidates: [EditorDocument], keeping anchor: EditorDocument) {
        for document in candidates.reversed() {
            guard let index = documents.firstIndex(where: { $0 === document }) else { continue }
            if !closeDocument(index) { break }
        }
        if let index = documents.firstIndex(where: { $0 === anchor }) { selectDocument(index) }
    }

    private func documentContextMenu(_ document: EditorDocument) -> NSMenu? {
        guard documents.contains(where: { $0 === document }) else { return nil }
        let menu = NSMenu(title: document.displayName)
        menu.autoenablesItems = false
        appendPathItems(to: menu, url: document.fileURL)
        menu.addItem(.separator())
        menu.addItem(actionItem("Save", enabled: document.isModified) { [weak self, weak document] in
            guard let self, let document else { return }
            self.withDocument(document) { self.save(document) }
        })
        menu.addItem(actionItem("Save As…") { [weak self, weak document] in
            guard let self, let document else { return }
            self.withDocument(document) { self.save(document, saveAs: true) }
        })
        menu.addItem(actionItem("Revert File…", enabled: document.fileURL != nil) { [weak self, weak document] in
            guard let self, let document else { return }
            self.withDocument(document) { _ = self.revertCurrentDocument() }
        })
        menu.addItem(.separator())
        menu.addItem(actionItem("Close Tab") { [weak self, weak document] in
            guard let self, let document, let index = self.documents.firstIndex(where: { $0 === document }) else { return }
            self.closeDocument(index)
        })
        for scope in TabCloseScope.allCases {
            menu.addItem(actionItem(scope.title, enabled: !closeCandidates(scope, anchor: document).isEmpty) { [weak self, weak document] in
                guard let self, let document else { return }
                self.closeDocuments(self.closeCandidates(scope, anchor: document), keeping: document)
            })
        }
        #if EDITOR_TESTS
        lastContextMenu = menu
        #endif
        return menu
    }

    private func editorContextMenu(_ text: EditorTextView) -> NSMenu? {
        guard let document = text.document, currentDocument === document else { return nil }
        let menu = NSMenu(title: "Editor")
        menu.autoenablesItems = false
        func edit(_ title: String, enabled: Bool = true, action: @escaping (EditorTextView) -> Void) {
            menu.addItem(actionItem(title, enabled: enabled) { [weak self, weak text] in
                guard let self, let text, self.currentDocument === text.document, self.panes.contains(where: { $0.textView === text }) else { return }
                self.window.makeFirstResponder(text)
                action(text)
                self.rebuildTabs()
                self.updateStatus()
            })
        }
        edit("Undo", enabled: document.undoManager.canUndo) { $0.document?.undoManager.undo() }
        edit("Redo", enabled: document.undoManager.canRedo) { $0.document?.undoManager.redo() }
        menu.addItem(.separator())
        let hasSelection = text.selectedRanges.contains { $0.rangeValue.length > 0 }
        edit("Cut", enabled: text.isEditable && hasSelection) { $0.cut(nil) }
        edit("Copy", enabled: hasSelection) { $0.copy(nil) }
        edit("Paste", enabled: text.isEditable && NSPasteboard.general.string(forType: .string) != nil) { $0.paste(nil) }
        edit("Delete", enabled: text.isEditable && hasSelection) { $0.deleteForward(nil) }
        edit("Select All") { $0.selectAll(nil) }
        menu.addItem(.separator())
        edit("Select Next Occurrence") { [weak self] _ in self?.selectNextOccurrence() }
        edit("Select All Occurrences") { [weak self] _ in self?.selectAllOccurrences() }
        edit("Indent") { [weak self] _ in self?.indent(outdent: false) }
        edit("Unindent") { [weak self] _ in self?.indent(outdent: true) }
        for (title, command) in [("Sort Lines", "sort_lines"), ("Uppercase", "upper_case"), ("Lowercase", "lower_case")] {
            edit(title) { [weak self] _ in _ = self?.executeCommand(command) }
        }
        menu.addItem(.separator())
        appendPathItems(to: menu, url: document.fileURL)
        #if EDITOR_TESTS
        lastContextMenu = menu
        #endif
        return menu
    }

    private func sidebarContextMenu(row: Int) -> NSMenu? {
        guard let item = outline.item(atRow: row) else { return nil }
        if let document = item as? EditorDocument { return documentContextMenu(document) }
        guard let node = item as? ProjectItem else { return nil }
        let menu = NSMenu(title: node.url.lastPathComponent)
        menu.autoenablesItems = false
        if !node.isDirectory {
            menu.addItem(actionItem("Open") { [weak self] in self?.openDocument(node.url) })
            menu.addItem(.separator())
        }
        appendPathItems(to: menu, url: node.url)
        menu.addItem(.separator())
        let parent = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
        for (title, folder) in [("New File…", false), ("New Folder…", true)] {
            menu.addItem(actionItem(title) { [weak self] in
                guard let self, let name = self.promptProjectName(title: title, initial: folder ? "New Folder" : "untitled.md") else { return }
                do { _ = try self.createProjectItem(in: parent, name: name, directory: folder) }
                catch { self.showError(error) }
            })
        }
        if node !== projectRoot {
            menu.addItem(actionItem("Rename…") { [weak self] in
                guard let self, let name = self.promptProjectName(title: "Rename", initial: node.url.lastPathComponent) else { return }
                do {
                    try ProjectFileOperations.validateName(name)
                    try self.moveProjectItem(node.url, to: node.url.deletingLastPathComponent().appendingPathComponent(name))
                } catch { self.showError(error) }
            })
            menu.addItem(actionItem("Move to Folder…") { [weak self] in
                guard let self else { return }
                let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
                panel.directoryURL = self.projectRoot?.url
                guard let folder = self.chooseFiles(panel)?.first else { return }
                do { try self.moveProjectItem(node.url, to: folder.appendingPathComponent(node.url.lastPathComponent)) }
                catch { self.showError(error) }
            })
            menu.addItem(actionItem("Move to Trash…") { [weak self] in
                guard let self else { return }
                let alert = NSAlert(); alert.messageText = "Move “\(node.url.lastPathComponent)” to Trash?"
                alert.informativeText = "Open buffers inside this item will remain in the editor as untitled documents."
                let cancel = EditorDialogs.addCancelButton(to: alert); cancel.keyEquivalent = "\r"
                alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
                alert.addButton(withTitle: "Move to Trash")
                guard self.runDialog(alert, cancelButton: cancel) == .alertSecondButtonReturn else { return }
                do { try self.trashProjectItem(node.url) } catch { self.showError(error) }
            })
        }
        menu.addItem(.separator())
        menu.addItem(actionItem("Refresh Folders") { [weak self] in
            self?.refreshProject()
        })
        #if EDITOR_TESTS
        lastContextMenu = menu
        #endif
        return menu
    }

    @discardableResult
    private func runDialog(_ alert: NSAlert, cancelButton: NSButton? = nil) -> NSApplication.ModalResponse {
        palette?.dismiss()
        return EditorDialogs.run(alert, for: window, cancelButton: cancelButton)
    }

    private func chooseFiles(_ panel: NSSavePanel) -> [URL]? {
        palette?.dismiss()
        return fileChooser.choose(panel, for: window)
    }

    @objc private func findInProject() {
        guard !pendingTermination, !pendingWindowClose, let root = projectRoot?.url else { return }
        if let existing = projectSearchPanel { existing.panel.makeKeyAndOrderFront(nil); return }
        palette?.dismiss()
        let search = ProjectSearchPanel(root: root)
        search.didClose = { [weak self] in self?.projectSearchPanel = nil }
        search.selectHit = { [weak self] in self?.openProjectSearchHit($0) }
        projectSearchPanel = search
        let text = currentTextView
        let selection = text?.selectedRange() ?? NSRange(location: 0, length: 0)
        let query = selection.length > 0 && selection.length <= 1024 ? (text!.string as NSString).substring(with: selection) : ""
        search.show(for: window, query: query)
    }

    func openProjectSearchHit(_ hit: ProjectSearchHit) {
        openDocument(hit.file)
        guard let document = currentDocument, document.fileURL == hit.file.standardizedFileURL.resolvingSymlinksInPath(), let view = currentTextView else { return }
        let text = document.storage.string as NSString
        guard hit.range.location >= 0, hit.range.length >= 0, hit.range.location <= text.length,
              hit.range.length <= text.length - hit.range.location, text.substring(with: hit.range) == hit.matchedText else {
            showError(EditorFailure.invalidEdit("The file changed after the search. Search again to locate the current text."))
            return
        }
        if markdownViewMode == .preview { setMarkdownMode(.edit) }
        view.setSelectedRange(hit.range)
        view.scrollRangeToVisible(hit.range)
        window.makeFirstResponder(view)
        updateStatus()
    }

    private func makeMarkdownBar() {
        markdownBar.orientation = .horizontal
        markdownBar.spacing = 10
        markdownBar.alignment = .centerY
        markdownBar.isHidden = true
        markdownModes.target = self
        markdownModes.action = #selector(markdownModeChanged)
        markdownModes.selectedSegment = 0
        markdownModes.setAccessibilityLabel("Markdown view mode")
        markdownModes.toolTip = "Edit source, read the rendered document, or show both"
        markdownOutline.target = self
        markdownOutline.action = #selector(showMarkdownOutline)
        markdownOutline.toolTip = "Render Markdown; in preview, navigate headings"
        markdownExport.target = self
        markdownExport.action = #selector(exportMarkdown)
        markdownInfo.font = .systemFont(ofSize: 11)
        markdownInfo.textColor = EditorTheme.muted
        markdownInfo.lineBreakMode = .byTruncatingTail
        markdownInfo.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [markdownModes, markdownInfo, NSView(), markdownOutline, markdownExport] { markdownBar.addArrangedSubview(view) }
    }

    var markdownViewMode: MarkdownViewMode {
        guard let document = currentDocument, document.syntaxIdentifier == "md" else { return .edit }
        return markdownModeCache[ObjectIdentifier(document)] ?? .edit
    }

    private func refreshMarkdown() {
        guard !pendingTermination, !pendingWindowClose else { releaseMarkdownPreview(); return }
        let supported = currentDocument?.syntaxIdentifier == "md"
        if markdownBar.isHidden == supported { markdownBar.isHidden = !supported; editorArea.needsLayout = true }
        let mode = markdownViewMode
        markdownModes.selectedSegment = mode.rawValue
        if editorSplit.isHidden != (mode == .preview) { editorSplit.isHidden = mode == .preview; contentSplit.needsLayout = true }
        guard supported, mode != .edit, let document = currentDocument else {
            releaseMarkdownPreview()
            refreshMarkdownInfo()
            return
        }
        if markdownPreview == nil {
            let preview = MarkdownPreviewView(frame: .zero)
            preview.didRender = { [weak self] in
                guard let self else { return }
                self.refreshMarkdownInfo()
                guard let pending = self.pendingMarkdownOutline,
                      self.currentDocument.map(ObjectIdentifier.init) == pending,
                      self.markdownPreview?.isRendering == false else { return }
                self.pendingMarkdownOutline = nil
                if self.markdownPreview?.page != nil {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.currentDocument.map(ObjectIdentifier.init) == pending,
                              self.markdownViewMode != .edit else { return }
                        self.showMarkdownOutline()
                    }
                }
            }
            preview.openFile = { [weak self] url in self?.openDocument(url) }
            markdownPreview = preview
            contentSplit.addArrangedSubview(preview)
            contentSplit.adjustSubviews()
            contentSplit.useFraction(0.5)
        }
        markdownPreview?.update(document: document, projectURL: projectRoot?.url, light: EditorTheme.isLight)
        refreshMarkdownInfo()
    }

    private func releaseMarkdownPreview() {
        pendingMarkdownOutline = nil
        guard let preview = markdownPreview else { return }
        preview.stop()
        contentSplit.removeArrangedSubview(preview)
        preview.removeFromSuperview()
        markdownPreview = nil
        contentSplit.adjustSubviews()
    }

    private func refreshMarkdownInfo() {
        let page = markdownPreview?.page
        markdownInfo.stringValue = page.map { "\($0.wordCount) words · \(max(1, ($0.wordCount + 219) / 220)) min read" } ?? "Markdown"
        markdownExport.isEnabled = page != nil && markdownPreview?.isRendering == false
        markdownOutline.isEnabled = currentDocument?.syntaxIdentifier == "md"
    }

    func setMarkdownMode(_ mode: MarkdownViewMode) {
        guard !pendingTermination, !pendingWindowClose, let document = currentDocument, document.syntaxIdentifier == "md" else { return }
        markdownModeCache[ObjectIdentifier(document)] = mode
        if mode == .preview { findBar.isHidden = true; editorArea.needsLayout = true }
        refreshMarkdown()
        contentSplit.adjustSubviews()
        contentSplit.useFraction(0.5)
        window.makeFirstResponder(mode == .preview ? markdownPreview?.webView : currentTextView)
    }
    @objc private func markdownModeChanged() { setMarkdownMode(MarkdownViewMode(rawValue: markdownModes.selectedSegment) ?? .edit) }
    @objc private func toggleMarkdownPreview() { setMarkdownMode(markdownViewMode == .preview ? .edit : .preview) }
    @objc private func markdownToSide() { setMarkdownMode(markdownViewMode == .sideBySide ? .edit : .sideBySide) }

    @objc private func showMarkdownOutline() {
        guard currentDocument?.syntaxIdentifier == "md" else { return }
        if markdownViewMode == .edit {
            setMarkdownMode(.preview)
            return
        }
        if markdownPreview?.isRendering == true {
            pendingMarkdownOutline = currentDocument.map(ObjectIdentifier.init)
            return
        }
        guard let headings = markdownPreview?.page?.headings, !headings.isEmpty else { return }
        let menu = NSMenu(title: "Markdown Outline")
        for heading in headings {
            let item = actionItem(heading.title) { [weak self] in self?.selectMarkdownHeading(heading) }
            item.indentationLevel = min(4, max(0, heading.level - 1))
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: markdownOutline.bounds.height), in: markdownOutline)
    }

    func selectMarkdownHeading(_ heading: MarkdownHeading) {
        guard let document = currentDocument, let text = currentTextView else { return }
        let starts = document.lineIndex.starts
        guard starts.indices.contains(heading.line - 1) else { return }
        text.setSelectedRange(NSRange(location: starts[heading.line - 1], length: 0))
        text.scrollRangeToVisible(text.selectedRange())
        markdownPreview?.showHeading(heading)
        updateStatus()
    }

    @objc private func exportMarkdown() {
        guard let page = markdownPreview?.page, markdownPreview?.isRendering == false else { return }
        let panel = NSSavePanel()
        panel.title = "Export Markdown as HTML"
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = (currentDocument?.fileURL?.deletingPathExtension().lastPathComponent ?? "document") + ".html"
        guard let destination = chooseFiles(panel)?.first else { return }
        do { try Data(page.exportHTML.utf8).write(to: destination, options: .atomic) }
        catch { showError(error) }
    }

    #if EDITOR_TESTS
    var markdownPreviewForTesting: MarkdownPreviewView? { markdownPreview }
    var projectSearchForTesting: ProjectSearchPanel? { projectSearchPanel }
    #endif

    @objc private func toggleSplit() {
        if let document = currentDocument, let text = currentTextView { selectionCache[ObjectIdentifier(document)] = text.selectedRanges }
        splitEnabled.toggle()
        activePane = 0
        rebuildPanes()
        updateStatus()
        window.makeFirstResponder(currentTextView)
    }

    @objc private func toggleSidebar() {
        guard let sidebar = projectSplit.arrangedSubviews.first else { return }
        sidebar.isHidden.toggle()
        projectSplit.adjustSubviews()
        if !sidebar.isHidden { projectSplit.setPosition(240, ofDividerAt: 0) }
    }

    private func replaceText(_ result: TextEditResult, name: String) {
        if let error = result.error {
            showError(EditorFailure.invalidEdit(error))
            return
        }
        guard let text = currentTextView as? EditorTextView else { return }
        text.applyEditorResult(result, name: name)
    }

    private func sort(caseSensitive: Bool = false, reverse: Bool = false, unique: Bool = false) {
        guard let text = currentTextView else { return }
        replaceText(TextOperations.sortLines(in: text.string, selections: text.selectedRanges.map(\.rangeValue),
                    caseSensitive: caseSensitive, reverse: reverse, removeDuplicates: unique), name: "Sort Lines")
    }
    @objc private func sortLines() { sort() }
    @objc private func sortCaseSensitive() { sort(caseSensitive: true) }
    @objc private func sortReverse() { sort(reverse: true) }
    @objc private func sortUnique() { sort(unique: true) }
    @objc private func uppercase() {
        guard let text = currentTextView else { return }
        replaceText(TextOperations.transform(in: text.string, selections: text.selectedRanges.map(\.rangeValue), upper: true), name: "Uppercase")
    }
    @objc private func lowercase() {
        guard let text = currentTextView else { return }
        replaceText(TextOperations.transform(in: text.string, selections: text.selectedRanges.map(\.rangeValue), upper: false), name: "Lowercase")
    }

    @objc private func showCommands() {
        let commands: [(String, String, () -> Void)] = [
            ("File: New", "⌘N", { [weak self] in self?.newFile() }),
            ("File: Open", "⌘O", { [weak self] in self?.openFile() }),
            ("Project: Open Folder", "⇧⌘O", { [weak self] in self?.openFolder() }),
            ("Project: Open Project File", "", { [weak self] in self?.openProjectFile() }),
            ("Project: Save Project As", "", { [weak self] in self?.saveProjectAs() }),
            ("Session: Save", "Explicit workspace snapshot", { [weak self] in self?.saveSession() }),
            ("Session: Restore", "Explicit session file", { [weak self] in self?.loadSession() }),
            ("File: Save", "⌘S", { [weak self] in self?.saveFile() }),
            ("File: Save As", "⇧⌘S", { [weak self] in self?.saveAs() }),
            ("File: Save All", "⌥⌘S", { [weak self] in self?.saveAll() }),
            ("File: Revert", "Reload from disk", { [weak self] in self?.revertFile() }),
            ("File: Copy File Path", "Full path", { [weak self] in self?.copyFilePath() }),
            ("File: Copy Relative File Path", "Relative to project", { [weak self] in self?.copyRelativeFilePath() }),
            ("File: Copy File Name", "Name with extension", { [weak self] in self?.copyFileName() }),
            ("File: Open Containing Folder", "Reveal in Finder", { [weak self] in self?.revealCurrentFile() }),
            ("File: Reveal in Side Bar", "Locate project file", { [weak self] in self?.revealCurrentFileInSidebar() }),
            ("File: Close Tab", "⌘W", { [weak self] in self?.closeTab() }),
            ("File: Reopen Closed File", "⇧⌘T", { [weak self] in self?.reopenClosedFile() }),
            ("View: Split Editor", "⌥⌘2 · shared document", { [weak self] in self?.toggleSplit() }),
            ("Markdown: Toggle Preview", "⇧⌘V", { [weak self] in self?.toggleMarkdownPreview() }),
            ("Markdown: Preview to the Side", "⌥⌘V", { [weak self] in self?.markdownToSide() }),
            ("Markdown: Document Outline", "Headings and source navigation", { [weak self] in self?.showMarkdownOutline() }),
            ("Markdown: Export HTML", "Standalone rendered document", { [weak self] in self?.exportMarkdown() }),
            ("Notes: New Markdown", "Blank note", { [weak self] in self?.newNote(.blank) }),
            ("Notes: Meeting Template", "Agenda, decisions and action items", { [weak self] in self?.newNote(.meeting) }),
            ("Notes: Daily Template", "Progress and next steps", { [weak self] in self?.newNote(.daily) }),
            ("Notes: Task Template", "To do and completed", { [weak self] in self?.newNote(.tasks) }),
            ("Notes: Toggle Task", "⇧⌘Return", { [weak self] in self?.toggleNoteTask() }),
            ("Notes: Bold", "⇧⌘B", { [weak self] in self?.noteBold() }),
            ("Notes: Italic", "⌘I", { [weak self] in self?.noteItalic() }),
            ("Notes: Inline Code", "Wrap current selections", { [weak self] in self?.noteCode() }),
            ("Notes: Code Block", "Wrap current selections", { [weak self] in self?.noteCodeBlock() }),
            ("Notes: Link", "Wrap current selections", { [weak self] in self?.noteLink() }),
            ("Notes: Date and Time", "Current local time", { [weak self] in self?.insertTimestamp() }),
            ("View: Toggle Sidebar", "⌃⌘B", { [weak self] in self?.toggleSidebar() }),
            ("View: Toggle Output", "", { [weak self] in self?.toggleOutput() }),
            ("Build: Run", "⌘B", { [weak self] in self?.runBuildAction() }),
            ("Build: Cancel", "⌃⌘.", { [weak self] in self?.cancelBuild() }),
            ("Build: Choose Configuration", "", { [weak self] in self?.chooseBuild() }),
            ("Plugin: Run Command", "Selected local Python plugin", { [weak self] in self?.runPluginAction() }),
            ("Plugin: Choose File", "", { [weak self] in self?.choosePlugin() }),
            ("Preferences: Load Configuration", "Font, tabs, theme and shortcuts", { [weak self] in self?.loadConfiguration() }),
            ("Preferences: Save Configuration", "Save supported editor settings", { [weak self] in self?.saveConfiguration() }),
            ("Preferences: Reset Configuration", "Restore editor defaults", { [weak self] in self?.resetConfiguration() }),
            ("Font: Larger", "⌘+", { [weak self] in self?.increaseFontSize() }),
            ("Font: Smaller", "⌘−", { [weak self] in self?.decreaseFontSize() }),
            ("Font: Reset", "", { [weak self] in self?.resetFontSize() }),
            ("Indentation: Indent", "⌘]", { [weak self] in self?.indentSelection() }),
            ("Indentation: Unindent", "⌘[", { [weak self] in self?.unindentSelection() }),
            ("Indentation: Convert to Spaces", "Entire buffer", { [weak self] in self?.convertIndentation(toSpaces: true) }),
            ("Indentation: Convert to Tabs", "Entire buffer", { [weak self] in self?.convertIndentation(toSpaces: false) }),
            ("Go to: File", "⌘P", { [weak self] in self?.quickOpen() }),
            ("Go to: Line", "⌘L", { [weak self] in self?.goToLine() }),
            ("Find: Search", "⌘F", { [weak self] in self?.showFind() }),
            ("Find: Search Project", "⇧⌘F · background disk search", { [weak self] in self?.findInProject() }),
            ("Find: Replace", "⌥⌘F", { [weak self] in self?.showReplace() }),
            ("Selection: Next Occurrence", "⌘D", { [weak self] in self?.selectNextOccurrence() }),
            ("Selection: All Occurrences", "⌃⌘G", { [weak self] in self?.selectAllOccurrences() }),
            ("Lines: Sort", "Case insensitive", { [weak self] in self?.sortLines() }),
            ("Lines: Duplicate", "⇧⌘D", { [weak self] in self?.duplicateLines() }),
            ("Lines: Delete", "⇧⌘K", { [weak self] in self?.deleteLines() }),
            ("Lines: Move Up", "⌥↑", { [weak self] in self?.moveLinesUp() }),
            ("Lines: Move Down", "⌥↓", { [weak self] in self?.moveLinesDown() }),
            ("Edit: Toggle Comment", "⌘/ · current syntax", { [weak self] in self?.toggleComment() }),
            ("Recovery: Toggle Auto Recovery", "Periodic snapshots of unsaved buffers", { [weak self] in self?.toggleAutoRecovery() }),
            ("Recovery: Restore Snapshot", "Recover in a new window", { [weak self] in self?.recoverSnapshot() }),
            ("Lines: Sort Case Sensitive", "", { [weak self] in self?.sortCaseSensitive() }),
            ("Lines: Reverse Sort", "", { [weak self] in self?.sortReverse() }),
            ("Lines: Unique Sorted", "Remove duplicate lines", { [weak self] in self?.sortUnique() }),
            ("Text: Uppercase", "Selections or current word", { [weak self] in self?.uppercase() }),
            ("Text: Lowercase", "Selections or current word", { [weak self] in self?.lowercase() }),
        ]
        var choices = commands.map { PaletteChoice(title: $0.0, detail: $0.1, action: $0.2) }
        func appendMenu(_ menu: NSMenu, prefix: String) {
            for item in menu.items {
                if let child = item.submenu { appendMenu(child, prefix: prefix + item.title + ": ") }
                else if item.isEnabled, let action = item.representedObject as? EditorMenuAction {
                    choices.append(PaletteChoice(title: prefix + item.title, detail: "Current document", action: action.run))
                }
            }
        }
        if let menu = status.encoding.menu { appendMenu(menu, prefix: "Encoding: ") }
        if let menu = recentFilesMenu { appendMenu(menu, prefix: "File: Open Recent: ") }
        if let menu = mainSyntaxMenu { appendMenu(menu, prefix: "Syntax: ") }
        if let menu = mainIndentationMenu { appendMenu(menu, prefix: "Indentation: ") }
        if let menu = mainLineEndingMenu { appendMenu(menu, prefix: "Line Endings: ") }
        palette.show(title: "Type a command…", choices: choices)
    }

    @objc private func quickOpen() {
        var choices: [PaletteChoice] = []
        for document in documents {
            choices.append(PaletteChoice(title: document.displayName, detail: "Open tab · \(document.fileURL?.path ?? "unsaved")") { [weak self, weak document] in
                guard let self, let document, let index = self.documents.firstIndex(where: { $0 === document }) else { return }
                self.selectDocument(index)
            })
        }
        let root = projectRoot?.url.path ?? ""
        let openPaths = Set(documents.compactMap { $0.fileURL?.path })
        for url in projectFiles where !openPaths.contains(url.path) {
            let relative = url.path.hasPrefix(root + "/") ? String(url.path.dropFirst(root.count + 1)) : url.path
            choices.append(PaletteChoice(title: url.lastPathComponent, detail: relative) { [weak self] in self?.openDocument(url) })
        }
        palette.show(title: projectRoot == nil ? "Find an open tab… (Open Folder to index project files)" : "Find a project file…", choices: choices)
    }

    @objc private func goToLine() {
        let alert = NSAlert()
        alert.messageText = "Go to Line"
        alert.informativeText = "Enter line or line:column (starting at 1)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        field.identifier = NSUserInterfaceItemIdentifier("dialog.goToLine")
        alert.accessoryView = field
        let goButton = alert.addButton(withTitle: "Go")
        let cancelButton = EditorDialogs.addCancelButton(to: alert)
        configureAlertInputs([field], firstResponder: field, submitButton: goButton, alert: alert)
        guard runDialog(alert, cancelButton: cancelButton) == .alertFirstButtonReturn else { return }
        let components = field.stringValue.split(separator: ":", omittingEmptySubsequences: false)
        guard let first = components.first, let line = Int(first), line > 0 else { NSSound.beep(); return }
        let column = components.count > 1 ? Int(components[1]) ?? 1 : 1
        jumpTo(line: line, column: max(1, column))
    }

    func jumpTo(line: Int, column: Int = 1) {
        guard let text = currentTextView else { return }
        let source = text.string as NSString
        let starts = TextOperations.lineStarts(in: text.string)
        let index = min(max(1, line) - 1, starts.count - 1)
        let start = starts[index]
        let end = index + 1 < starts.count ? starts[index + 1] : source.length
        let position = start + min(max(1, column) - 1, end - start)
        text.setSelectedRange(NSRange(location: position, length: 0))
        text.scrollRangeToVisible(text.selectedRange())
        window.makeFirstResponder(text)
    }

    private func enableFind(replace: Bool) {
        findBar.isHidden = false
        replaceRow.isHidden = !replace
        editorArea.needsLayout = true
        if let text = currentTextView, text.selectedRange().length > 0 {
            findField.stringValue = (text.string as NSString).substring(with: text.selectedRange())
        }
        window.makeFirstResponder(findField)
        updateFindCount()
    }
    @objc private func showFind() { enableFind(replace: false) }
    @objc private func showReplace() { enableFind(replace: true) }
    @objc private func hideFind() { findBar.isHidden = true; editorArea.needsLayout = true; window.makeFirstResponder(currentTextView) }

    private var findKey: FindKey? {
        guard let document = currentDocument else { return nil }
        return FindKey(document: ObjectIdentifier(document), revision: document.revision,
            query: findField.stringValue, regex: regexToggle.state == .on, caseSensitive: caseToggle.state == .on)
    }
    private func requestFind(immediate: Bool = false, action: (() -> Void)? = nil) {
        guard !closed, !pendingTermination, !pendingWindowClose, let key = findKey else { return }
        guard !key.query.isEmpty else {
            searchDebounce?.cancel(); searchWorker.cancel(); searchGeneration += 1
            requestedFindKey = nil; cachedFindKey = nil; cachedFindRanges = []; pendingFindAction = nil
            findMessage.stringValue = ""; return
        }
        if cachedFindKey == key { action?(); return }
        if requestedFindKey == key {
            if let action { pendingFindAction = action }
            if immediate, searchDebounce != nil { searchDebounce?.cancel(); searchDebounce = nil; launchFind(key, generation: searchGeneration) }
            return
        }
        searchDebounce?.cancel(); searchWorker.cancel(); searchGeneration += 1
        requestedFindKey = key; cachedFindKey = nil; cachedFindRanges = []; pendingFindAction = action
        findMessage.stringValue = "Searching…"; findMessage.toolTip = nil
        let generation = searchGeneration
        if immediate { searchDebounce = nil; launchFind(key, generation: generation) }
        else {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.searchGeneration == generation else { return }
                self.searchDebounce = nil; self.launchFind(key, generation: generation)
            }
            searchDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
    }
    private func launchFind(_ key: FindKey, generation: Int) {
        guard findKey == key, let text = currentTextView?.string else { return }
        searchWorker.submit(SearchOperation { [weak self] operation in
            let outcome = Result { try SearchEngine.scan(in: text, query: key.query, regex: key.regex,
                caseSensitive: key.caseSensitive, isCancelled: { operation.isCancelled }) }
            guard !operation.isCancelled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed, self.searchGeneration == generation, self.findKey == key else { return }
                self.requestedFindKey = nil
                switch outcome {
                case .success(let result):
                    self.cachedFindKey = key; self.cachedFindRanges = result.ranges
                    self.findMessage.stringValue = "\(result.matches.count) matches" + (result.limit.map { " · Partial: " + $0 } ?? "")
                    self.findMessage.toolTip = result.limit
                    let action = self.pendingFindAction; self.pendingFindAction = nil; action?()
                case .failure(let error):
                    self.pendingFindAction = nil
                    self.findMessage.stringValue = error.localizedDescription
                    self.findMessage.toolTip = error.localizedDescription
                }
            }
        })
    }
    private func updateFindCount() { if !findBar.isHidden { requestFind() } }
    func controlTextDidChange(_ obj: Notification) { updateFindCount() }
    @objc private func searchOptionsChanged() { updateFindCount() }

    private func find(backward: Bool) {
        requestFind(immediate: true) { [weak self] in
            guard let self, let text = self.currentTextView, !self.cachedFindRanges.isEmpty else { NSSound.beep(); return }
            let selection = text.selectedRange(), matches = self.cachedFindRanges
            let match: NSRange
            if backward { match = matches.last(where: { $0.location < selection.location }) ?? matches.last! }
            else {
                let start = NSMaxRange(selection) + (selection.length == 0 ? 1 : 0)
                match = matches.first(where: { $0.location >= start }) ?? matches.first!
            }
            text.setSelectedRange(match); text.scrollRangeToVisible(match); self.updateStatus()
        }
    }
    @objc private func findNext() { find(backward: false) }
    @objc private func findPrevious() { find(backward: true) }

    @objc private func replaceOne() {
        requestFind(immediate: true) { [weak self] in
            guard let self, let text = self.currentTextView else { return }
            guard let match = self.cachedFindRanges.first(where: { $0 == text.selectedRange() }) else { self.findNext(); return }
            self.replaceSearch(range: match)
        }
    }
    @objc private func replaceAll() { replaceSearch(range: nil) }
    private func replaceSearch(range: NSRange?) {
        guard !closed, !pendingTermination, !pendingWindowClose, let key = findKey, !key.query.isEmpty,
              let text = currentTextView?.string else { return }
        let replacement = replaceField.stringValue
        searchDebounce?.cancel(); searchDebounce = nil; searchWorker.cancel(); searchGeneration += 1
        let generation = searchGeneration
        requestedFindKey = nil; pendingFindAction = nil
        findMessage.stringValue = "Replacing…"
        searchWorker.submit(SearchOperation { [weak self] operation in
            let outcome = Result { try SearchEngine.replacing(in: text, query: key.query, replacement: replacement,
                regex: key.regex, caseSensitive: key.caseSensitive, range: range, isCancelled: { operation.isCancelled }) }
            guard !operation.isCancelled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed, self.searchGeneration == generation else { return }
                guard self.findKey == key else { self.findMessage.stringValue = "File/query changed; replacement was not applied."; return }
                switch outcome {
                case .success(let result):
                    self.replaceText(result, name: range == nil ? "Replace All" : "Replace")
                    if range != nil { self.findNext() } else { self.updateFindCount() }
                case .failure(let error): self.findMessage.stringValue = error.localizedDescription; self.findMessage.toolTip = error.localizedDescription
                }
            }
        })
    }

    private func occurrenceSelection() -> (NSTextView, NSString, NSRange)? {
        guard let text = currentTextView else { return nil }
        let source = text.string as NSString
        var selection = text.selectedRanges.first?.rangeValue ?? text.selectedRange()
        if selection.length == 0, source.length > 0 {
            selection = text.selectionRange(forProposedRange: selection, granularity: .selectByWord)
            text.setSelectedRange(selection)
        }
        guard selection.length > 0, NSMaxRange(selection) <= source.length else { return nil }
        return (text, source, selection)
    }

    @objc private func selectNextOccurrence() {
        guard let (text, source, selection) = occurrenceSelection() else { return }
        let needle = source.substring(with: selection)
        let selected = text.selectedRanges.map(\.rangeValue)
        let start = min(source.length, selected.map(NSMaxRange).max() ?? NSMaxRange(selection))
        var match = source.range(of: needle, options: [], range: NSRange(location: start, length: source.length - start))
        if match.location == NSNotFound { match = source.range(of: needle, options: [], range: NSRange(location: 0, length: start)) }
        guard match.location != NSNotFound, !selected.contains(match) else { return }
        text.selectedRanges = (selected + [match]).sorted { $0.location < $1.location }.map { NSValue(range: $0) }
        text.scrollRangeToVisible(match)
        window.makeFirstResponder(text)
    }

    @objc private func selectAllOccurrences() {
        guard let (text, source, selection) = occurrenceSelection() else { return }
        let needle = source.substring(with: selection)
        var ranges: [NSValue] = []
        var start = 0
        while start < source.length {
            let range = source.range(of: needle, options: [], range: NSRange(location: start, length: source.length - start))
            if range.location == NSNotFound { break }
            ranges.append(NSValue(range: range))
            start = NSMaxRange(range)
        }
        if !ranges.isEmpty { text.selectedRanges = ranges }
        window.makeFirstResponder(text)
    }

    // A small public-to-the-module surface supports executable GUI smoke checks.
    func newNote(_ template: NoteTemplate) {
        var settings = documentDefaults; settings.syntax = "markdown"
        let document = EditorDocument(settings: settings)
        document.setTextUndoably(template.text(), actionName: "Note Template")
        addDocument(document)
    }
    @objc private func toggleNoteTask() {
        guard markdownViewMode != .preview, let document = currentDocument, document.resolvedSyntax == .markdown, let view = currentTextView,
              !view.hasMarkedText() else { NSSound.beep(); return }
        replaceText(NoteEditing.toggleTasks(in: document.storage.string, selections: view.selectedRanges.map(\.rangeValue)), name: "Toggle Markdown Task")
    }
    private func wrapNote(_ opening: String, _ closing: String) {
        guard markdownViewMode != .preview, let document = currentDocument, document.resolvedSyntax == .markdown, let view = currentTextView,
              !view.hasMarkedText() else { NSSound.beep(); return }
        replaceText(NoteEditing.wrap(document.storage.string, selections: view.selectedRanges.map(\.rangeValue), opening: opening, closing: closing), name: "Markdown Formatting")
    }
    @objc private func noteBold() { wrapNote("**", "**") }
    @objc private func noteItalic() { wrapNote("*", "*") }
    @objc private func noteCode() { wrapNote("`", "`") }
    @objc private func noteCodeBlock() { let end = currentDocument?.settings.lineEnding.text ?? "\n"; wrapNote("```" + end, end + "```") }
    @objc private func noteLink() { wrapNote("[", "](https://)") }
    @objc private func insertTimestamp() {
        guard markdownViewMode != .preview, let view = currentTextView, !view.hasMarkedText() else { return }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH:mm"; formatter.locale = Locale(identifier: "en_US_POSIX")
        replaceText(TextOperations.apply(in: view.string, edits: view.selectedRanges.map { .init(range: $0.rangeValue, text: formatter.string(from: Date())) }), name: "Insert Date and Time")
    }
    func insertNoteImage(_ data: Data) {
        guard markdownViewMode != .preview, let document = currentDocument, document.resolvedSyntax == .markdown, let view = currentTextView,
              !view.hasMarkedText(), TextOperations.valid(view.string, view.selectedRanges.map(\.rangeValue)) else { return }
        guard document.fileURL != nil || save(document), let url = document.fileURL else { return }
        do {
            let asset = try NoteAssets.insertImage(data, beside: url)
            let result = TextOperations.apply(in: view.string, edits: view.selectedRanges.map { .init(range: $0.rangeValue, text: asset.markdown) })
            if result.error != nil { try? FileManager.default.removeItem(at: asset.url); showError(EditorFailure.invalidEdit(result.error!)); return }
            replaceText(result, name: "Paste Markdown Image")
            if document.storage.string != result.text { try? FileManager.default.removeItem(at: asset.url) }
            refreshProject()
        } catch { showError(error) }
    }

    func executeCommand(_ name: String) -> Bool {
        switch name {
        case "new_file": newFile()
        case "new_window": newWindow()
        case "save": saveFile()
        case "save_all": saveAll()
        case "revert": revertFile()
        case "reopen_closed_file": reopenClosedFile()
        case "close_tab": closeTab()
        case "copy_path": copyFilePath()
        case "copy_relative_path": copyRelativeFilePath()
        case "copy_file_name": copyFileName()
        case "reveal_in_side_bar": revealCurrentFileInSidebar()
        case "split": toggleSplit()
        case "markdown_preview": toggleMarkdownPreview()
        case "markdown_side": markdownToSide()
        case "markdown_edit": setMarkdownMode(.edit)
        case "markdown_export": exportMarkdown()
        case "note_new": newNote(.blank)
        case "note_meeting": newNote(.meeting)
        case "note_daily": newNote(.daily)
        case "note_tasks": newNote(.tasks)
        case "markdown_task": toggleNoteTask()
        case "markdown_bold": noteBold()
        case "markdown_italic": noteItalic()
        case "markdown_code": noteCode()
        case "markdown_code_block": noteCodeBlock()
        case "markdown_link": noteLink()
        case "insert_timestamp": insertTimestamp()
        case "sort_lines": sortLines()
        case "upper_case": uppercase()
        case "lower_case": lowercase()
        case "select_next": selectNextOccurrence()
        case "select_all_occurrences": selectAllOccurrences()
        case "find": showFind()
        case "find_in_project": findInProject()
        case "command_palette": showCommands()
        case "dismiss_palette": palette.dismiss()
        case "quick_open": quickOpen()
        case "build": runBuildAction()
        case "cancel_build": cancelBuild()
        case "run_plugin": runPluginAction()
        case "configure": loadConfiguration()
        case "save_configuration": saveConfiguration()
        case "reset_configuration": resetConfiguration()
        case "font_increase": increaseFontSize()
        case "font_decrease": decreaseFontSize()
        case "font_reset": resetFontSize()
        case "indent": indentSelection()
        case "duplicate_lines": duplicateLines()
        case "delete_lines": deleteLines()
        case "move_lines_up": moveLinesUp()
        case "move_lines_down": moveLinesDown()
        case "toggle_comment": toggleComment()
        case "unindent": unindentSelection()
        case "save_session": saveSession()
        case "restore_session": loadSession()
        default: return false
        }
        return true
    }

    #if EDITOR_TESTS
    var recoveryURLForTesting: URL? { recovery?.url }
    var recoveryMessageForTesting: String { recoveryMessage }
    func updateRecoveryForTesting() { recoverySignature = "force"; updateRecoverySnapshot() }
    var snapshot: [String: Any] {
        ["title": window?.title ?? "", "documentCount": documents.count,
         "selectedIndex": selectedIndex, "paneCount": panes.count,
         "text": currentDocument?.storage.string ?? "", "modified": currentDocument?.isModified ?? false,
         "selectionCount": currentTextView?.selectedRanges.count ?? 0,
         "projectFiles": projectFiles.count, "status": status.location.stringValue,
         "projectRoot": projectRoot?.url.path ?? "",
         "encoding": status.encoding.title, "lineEnding": status.lineEnding.title,
         "indentation": status.indentation.title, "syntax": status.syntax.title,
         "menuActionCount": menuActionCount,
         "lastMenuActionID": lastMenuActionID,
         "rulerLineNumbers": panes.map { $0.ruler.visibleLineNumbers },
         "paletteVisible": palette?.panel.isVisible ?? false,
         "recentFiles": recentFiles.urls.map(\.path),
         "outputVisible": !outputArea.isHidden, "output": outputView.string,
         "buildRunning": isBuildRunning, "pluginRunning": isPluginRunning,
         "outputTrimmed": outputWasTrimmed, "buildLog": buildRunner.logURL?.path ?? "",
         "findMessage": findMessage.stringValue, "findMatches": cachedFindRanges.count,
         "diskChangeCount": diskChanges.count, "notice": noticeBar.isHidden ? "" : noticeLabel.stringValue,
         "monitorActive": fileMonitoringEnabled && !closed,
         "theme": EditorTheme.isLight ? "light" : "dark"]
    }
    #endif
}
