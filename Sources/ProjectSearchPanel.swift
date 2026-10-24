import AppKit

private final class ProjectResultsTable: NSTableView {
    var openSelection: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { openSelection?() }
        else { super.keyDown(with: event) }
    }
}

final class ProjectSearchPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let panel: NSPanel
    private let root: URL
    private let field = NSSearchField()
    private let caseToggle = NSButton(checkboxWithTitle: "Match case", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "Search text files in this project")
    private let table = ProjectResultsTable()
    private let queue = OperationQueue()
    private var debounce: Timer?
    private var operation: ProjectSearchOperation?
    private var generation = 0
    private var hits: [ProjectSearchHit] = []
    private(set) var report: ProjectSearchReport?
    private(set) var isSearching = false
    var selectHit: ((ProjectSearchHit) -> Void)?
    var didClose: (() -> Void)?

    init(root: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 780, height: 490),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        super.init()
        panel.title = "Find in Project — " + root.lastPathComponent
        panel.minSize = NSSize(width: 560, height: 340)
        panel.isReleasedWhenClosed = false
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        queue.name = "SourceEditor.ProjectSearch"
        let content = NSView()
        panel.contentView = content
        field.placeholderString = "Search project files…"
        field.delegate = self
        field.target = self
        field.action = #selector(searchNow)
        field.setAccessibilityLabel("Find in project")
        caseToggle.target = self
        caseToggle.action = #selector(searchNow)
        let close = NSButton(title: "Close", target: self, action: #selector(closePanel))
        close.keyEquivalent = "\u{1b}"
        let cancel = NSButton(title: "Stop", target: self, action: #selector(stopSearch))
        let controls = NSStackView(views: [caseToggle, NSView(), cancel, close])
        controls.orientation = .horizontal
        controls.spacing = 12
        let hint = NSTextField(labelWithString: "Literal text • disk files • double-click or press Return to open")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 12)
        status.lineBreakMode = .byTruncatingTail
        let column = NSTableColumn(identifier: .init("match"))
        column.title = "Results"
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 48
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openResult)
        table.openSelection = { [weak self] in self?.openResult() }
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel("Project search results")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        for view in [field, hint, controls, status, scroll] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 16), field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            hint.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 6), hint.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            controls.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 10), controls.leadingAnchor.constraint(equalTo: field.leadingAnchor), controls.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 10), scroll.leadingAnchor.constraint(equalTo: field.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            status.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10), status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            status.leadingAnchor.constraint(equalTo: field.leadingAnchor), status.trailingAnchor.constraint(equalTo: field.trailingAnchor),
        ])
    }
    deinit { debounce?.invalidate(); queue.cancelAllOperations() }

    func show(for window: NSWindow, query: String = "") {
        field.stringValue = query
        window.beginSheet(panel)
        panel.makeFirstResponder(field)
        if !query.isEmpty { startSearch(immediate: true) }
    }
    func controlTextDidChange(_ obj: Notification) { startSearch(immediate: false) }
    @objc private func searchNow() { startSearch(immediate: true) }

    private func startSearch(immediate: Bool) {
        generation += 1
        let current = generation
        debounce?.invalidate()
        queue.cancelAllOperations()
        hits.removeAll()
        report = nil
        table.reloadData()
        let query = field.stringValue
        guard !query.isEmpty else { isSearching = false; status.stringValue = "Search text files in this project"; return }
        isSearching = true
        status.stringValue = "Searching…"
        let request = ProjectSearchOperation(root: root, query: query, caseSensitive: caseToggle.state == .on)
        operation = request
        request.completionBlock = { [weak self, weak request] in
            guard let report = request?.report, request?.isCancelled == false else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == current else { return }
                self.isSearching = false
                self.report = report
                self.hits = report.hits
                self.table.reloadData()
                let limit = report.limitReason.map { " • \($0)" } ?? ""
                self.status.stringValue = "\(report.hits.count) matches • \(report.searchedFiles) files searched • \(report.skippedFiles + report.scan.unreadable) skipped\(limit)"
                self.status.toolTip = "Hidden files, packages, symlinks, node_modules and __pycache__ are excluded. Files over 2 MiB and undecodable/binary data are skipped."
            }
        }
        if immediate { queue.addOperation(request) }
        else { debounce = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self, weak request] _ in
            guard let self, let request, self.generation == current else { return }
            self.queue.addOperation(request)
        } }
    }

    @objc private func stopSearch() {
        generation += 1
        debounce?.invalidate()
        operation?.cancel()
        queue.cancelAllOperations()
        isSearching = false
        status.stringValue = "Search stopped"
    }
    @objc private func closePanel() { close() }
    func close() {
        stopSearch()
        panel.sheetParent?.endSheet(panel)
        panel.orderOut(nil)
        didClose?()
    }
    @objc private func openResult() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard hits.indices.contains(row) else { return }
        let hit = hits[row]
        let callback = selectHit
        close()
        callback?(hit)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)), !hits.isEmpty {
            table.selectRowIndexes(IndexSet(integer: max(0, table.selectedRow)), byExtendingSelection: false)
            openResult(); return true
        }
        return false
    }
    func numberOfRows(in tableView: NSTableView) -> Int { hits.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard hits.indices.contains(row) else { return nil }
        let hit = hits[row]
        let view = NSTableCellView()
        let relative = hit.file.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
        let title = NSTextField(labelWithString: "\(relative):\(hit.line)")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        let excerpt = NSTextField(labelWithString: hit.excerpt)
        excerpt.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        excerpt.textColor = .secondaryLabelColor
        excerpt.lineBreakMode = .byTruncatingTail
        for label in [title, excerpt] { label.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(label) }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10), title.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10), title.topAnchor.constraint(equalTo: view.topAnchor, constant: 5),
            excerpt.leadingAnchor.constraint(equalTo: title.leadingAnchor), excerpt.trailingAnchor.constraint(equalTo: title.trailingAnchor), excerpt.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
        ])
        return view
    }
    #if EDITOR_TESTS
    func searchForTesting(_ query: String) { field.stringValue = query; startSearch(immediate: true) }
    func openFirstForTesting() { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); openResult() }
    #endif
}
