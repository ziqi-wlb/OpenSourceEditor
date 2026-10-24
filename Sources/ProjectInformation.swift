import AppKit

/// Authored project metadata owns both the native information view and generated release documents.
struct ProjectInformation: Decodable {
    struct Translation: Decodable {
        let english: String
        let chinese: String
        func text(chinese: Bool) -> String { chinese ? self.chinese : english }
    }
    struct Release: Decodable {
        let version: String
        let changes: [Translation]
    }
    let author: String
    let email: String
    let overview: Translation
    let releases: [Release]

    static func load() throws -> ProjectInformation {
        guard let url = Bundle.main.url(forResource: "project-information", withExtension: "json") else {
            throw EditorFailure.invalidEdit("Project information is missing from this application bundle.")
        }
        return try JSONDecoder().decode(ProjectInformation.self, from: Data(contentsOf: url))
    }

    var contactURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email
        components.queryItems = [URLQueryItem(name: "subject", value: "Source Editor feedback")]
        return components.url
    }
}

/// The scroll viewport owns wrapping width; NSTextView owns its growing height.
private final class ProjectInformationScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let text = documentView as? NSTextView, contentSize.width > 0 else { return }
        let width = contentSize.width
        text.maxSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        if text.frame.width != width {
            text.setFrameSize(NSSize(width: width, height: text.frame.height))
        }
    }
}

final class ProjectInformationWindowController: NSWindowController {
    enum Section: Int { case about, releases }
    let information: ProjectInformation
    private(set) var section = Section.about
    private let sectionControl = NSSegmentedControl(labels: ["About", "Release Notes"], trackingMode: .selectOne, target: nil, action: nil)
    private let languageControl = NSSegmentedControl(labels: ["English", "中文"], trackingMode: .selectOne, target: nil, action: nil)
    private let authorLabel = NSTextField(labelWithString: "")
    private let contactButton = NSButton(title: "Contact Author", target: nil, action: nil)
    private let textView = NSTextView()
    private var chinese: Bool { languageControl.selectedSegment == 1 }

    init(information: ProjectInformation) {
        self.information = information
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 550),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 520, height: 380)
        window.center()
        let content = NSView()
        window.contentView = content
        let title = NSTextField(labelWithString: "Source Editor")
        title.font = .systemFont(ofSize: 23, weight: .semibold)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let versionLabel = NSTextField(labelWithString: version)
        versionLabel.textColor = .secondaryLabelColor
        let identity = NSStackView(views: [title, versionLabel])
        identity.alignment = .firstBaseline
        identity.spacing = 12
        let controls = NSStackView(views: [sectionControl, NSView(), languageControl])
        controls.spacing = 12
        let footer = NSStackView(views: [authorLabel, NSView(), contactButton])
        footer.spacing = 12
        let scroll = ProjectInformationScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 20, height: 18)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.frame = NSRect(x: 0, y: 0, width: 650, height: 400)
        textView.maxSize = NSSize(width: textView.frame.width, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        for view in [identity, controls, scroll, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            identity.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            identity.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            controls.leadingAnchor.constraint(equalTo: identity.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            controls.topAnchor.constraint(equalTo: identity.bottomAnchor, constant: 18),
            scroll.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 16),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -16),
            footer.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
        ])
        sectionControl.target = self
        sectionControl.action = #selector(changeSection)
        sectionControl.setAccessibilityLabel("Information section")
        languageControl.target = self
        languageControl.action = #selector(changeLanguage)
        languageControl.setAccessibilityLabel("Information language")
        languageControl.selectedSegment = Locale.preferredLanguages.first?.hasPrefix("zh") == true ? 1 : 0
        contactButton.target = self
        contactButton.action = #selector(contactAuthor)
        contactButton.bezelStyle = .rounded
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ section: Section) {
        self.section = section
        refresh()
        window?.deminiaturize(nil)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func changeSection() {
        section = Section(rawValue: sectionControl.selectedSegment) ?? .about
        refresh()
    }
    @objc private func changeLanguage() { refresh() }
    @objc private func contactAuthor() {
        if let url = information.contactURL { NSWorkspace.shared.open(url) }
    }

    private func refresh() {
        sectionControl.selectedSegment = section.rawValue
        sectionControl.setLabel(chinese ? "项目介绍" : "About", forSegment: 0)
        sectionControl.setLabel(chinese ? "版本说明" : "Release Notes", forSegment: 1)
        window?.title = "Source Editor — " + (section == .about ? (chinese ? "项目介绍" : "About") : (chinese ? "版本说明" : "Release Notes"))
        authorLabel.stringValue = (chinese ? "作者：" : "Author: ") + information.author + " · " + information.email
        contactButton.title = chinese ? "联系作者" : "Contact Author"
        contactButton.toolTip = information.email
        let body = NSMutableAttributedString(string: "")
        func append(_ text: String, heading: Bool = false) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = heading ? 10 : 12
            paragraph.lineSpacing = 4
            body.append(NSAttributedString(string: text + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: heading ? 19 : 14, weight: heading ? .semibold : .regular),
                .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
            ]))
        }
        if section == .about {
            append(chinese ? "独立、原生、本地" : "Independent, native, local", heading: true)
            append(information.overview.text(chinese: chinese))
        } else {
            for release in information.releases {
                append("Source Editor " + release.version, heading: true)
                for change in release.changes { append("• " + change.text(chinese: chinese)) }
            }
        }
        textView.textStorage?.setAttributedString(body)
        // Reset the viewport rather than reveal a zero-length caret. AppKit's
        // caret scrolling can shift a read-only view horizontally past its inset.
        if let scroll = textView.enclosingScrollView {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        textView.setAccessibilityLabel(chinese ? "项目信息正文" : "Project information content")
    }
}
