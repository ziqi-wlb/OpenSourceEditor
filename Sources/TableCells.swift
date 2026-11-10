import AppKit

/// Build controls and constraints once; tables reuse the cell by identifier.
final class SidebarTableCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("sidebar.file")
    let label = NSTextField(labelWithString: "")
    let icon = NSImageView()

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        textField = label; imageView = icon
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingMiddle
        for view in [icon, label] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        // reloadData can detach a cell before the row-removal callback sees it.
        if newSuperview == nil { toolTip = nil; removeAllToolTips() }
        super.viewWillMove(toSuperview: newSuperview)
    }
}

func reusableTableRow(in table: NSTableView, identifier: String) -> NSTableRowView {
    let identifier = NSUserInterfaceItemIdentifier(identifier)
    let row = table.makeView(withIdentifier: identifier, owner: nil) as? NSTableRowView ?? NSTableRowView()
    row.identifier = identifier
    return row
}

final class TwoLineTableCell: NSTableCellView {
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier, inset: CGFloat, titleFont: NSFont, detailFont: NSFont) {
        super.init(frame: .zero)
        self.identifier = identifier
        textField = title
        title.font = titleFont; detail.font = detailFont
        for label in [title, detail] { label.translatesAutoresizingMaskIntoConstraints = false; addSubview(label) }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
