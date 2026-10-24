import AppKit

// Presentation only: document settings and all edit semantics remain in the
// document/application owners. Menus are supplied by the window controller.
final class EditorStatusBar: NSView {
    let location = NSTextField(labelWithString: "")
    let encoding = NSPopUpButton(frame: .zero, pullsDown: true)
    let lineEnding = NSPopUpButton(frame: .zero, pullsDown: true)
    let indentation = NSPopUpButton(frame: .zero, pullsDown: true)
    let syntax = NSPopUpButton(frame: .zero, pullsDown: true)
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        location.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        location.lineBreakMode = .byTruncatingTail
        location.identifier = NSUserInterfaceItemIdentifier("status.location")
        addSubview(location)
        for (name, button) in [("encoding", encoding), ("lineEnding", lineEnding),
                               ("indentation", indentation), ("syntax", syntax)] {
            button.identifier = NSUserInterfaceItemIdentifier("status." + name)
            button.font = NSFont.systemFont(ofSize: 11)
            button.isBordered = false
            button.bezelStyle = .inline
            button.focusRingType = .default
            addSubview(button)
        }
        encoding.toolTip = "Set encoding or reopen with another encoding"
        lineEnding.toolTip = "Choose line endings"
        indentation.toolTip = "Choose indentation, tab width or convert existing indentation"
        syntax.toolTip = "Choose syntax highlighting"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setMenu(_ menu: NSMenu, title: String, for button: NSPopUpButton) {
        let label = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        // A pull-down's first item owns its display title. Keep that title out
        // of the action menu without marking the usable control as disabled.
        label.isHidden = true
        menu.insertItem(label, at: 0)
        button.menu = menu
        button.selectItem(at: 0)
        needsLayout = true
    }

    func style(foreground: NSColor, background: NSColor) {
        location.textColor = foreground
        for button in [encoding, lineEnding, indentation, syntax] { button.contentTintColor = foreground }
        wantsLayer = true
        layer?.backgroundColor = background.cgColor
    }

    override func layout() {
        super.layout()
        var x = bounds.width - 8
        for button in [syntax, indentation, lineEnding, encoding] where !button.isHidden {
            let titleWidth = (button.title as NSString).size(withAttributes: [.font: button.font!]).width
            let width = min(200, max(52, titleWidth + 26))
            x -= width
            button.frame = NSRect(x: x, y: 0, width: width, height: bounds.height)
            x -= 5
        }
        location.frame = NSRect(x: 14, y: max(0, (bounds.height - 18) / 2), width: max(0, x - 20), height: 18)
    }
}
