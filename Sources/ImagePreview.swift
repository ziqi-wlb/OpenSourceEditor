import AppKit
import ImageIO

/// Image documents retain metadata and a URL, never a text interpretation of binary bytes.
struct EditorImageAsset: Equatable {
    static let extensions: Set<String> = ["png", "jpg", "jpeg", "jpe", "gif", "bmp", "tif", "tiff", "heic", "heif", "webp", "ico"]
    static let maximumFileBytes = 128 * 1024 * 1024
    static let maximumSourcePixels = 64_000_000
    static let thumbnailEdge = 2048 // At most 16 MiB of RGBA pixels per visible pane.
    let url: URL
    let width: Int
    let height: Int
    let bytes: Int
    let modified: Date?
    let frames: Int
    var size: NSSize { NSSize(width: width, height: height) }
    var summary: String { "\(width) × \(height) px · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))" + (frames > 1 ? " · First frame of \(frames)" : "") }

    static func supports(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }
    static func load(_ url: URL) throws -> Self {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
        guard values.isRegularFile == true, let bytes = values.fileSize, bytes <= maximumFileBytes else {
            throw EditorFailure.invalidEdit("Image preview requires a regular file no larger than 128 MiB.")
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              w > 0, h > 0, w <= 100_000, h <= 100_000 else {
            throw EditorFailure.invalidEdit("This image is damaged or its format is not supported by macOS ImageIO.")
        }
        guard w <= maximumSourcePixels / h else {
            throw EditorFailure.invalidEdit("Image preview supports up to 64 million source pixels. Reduce the image dimensions before opening it.")
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return Self(url: url, width: (5...8).contains(orientation) ? h : w,
            height: (5...8).contains(orientation) ? w : h, bytes: bytes,
            modified: values.contentModificationDate, frames: CGImageSourceGetCount(source))
    }
    func thumbnail() throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Self.thumbnailEdge,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else {
            throw EditorFailure.invalidEdit("The image could not be decoded. Try Reload Image after checking the file.")
        }
        return image
    }
}

private final class ImageDecodeOperation: Operation, @unchecked Sendable {
    let asset: EditorImageAsset
    var result: Result<CGImage, Error>?
    init(_ asset: EditorImageAsset) { self.asset = asset }
    override func main() {
        guard !isCancelled else { return }
        let decoded = Result { try asset.thumbnail() }
        if !isCancelled { result = decoded }
    }
}

private final class ImageCanvas: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var imageSize = NSSize.zero
    var activate: (() -> Void)?
    var context: (() -> NSMenu?)?
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) { activate?() }
    override func menu(for event: NSEvent) -> NSMenu? { activate?(); return context?() }
    override func draw(_ dirtyRect: NSRect) {
        EditorTheme.background.setFill(); dirtyRect.fill()
        guard let image else { return }
        let rect = NSRect(x: (bounds.width - imageSize.width) / 2, y: (bounds.height - imageSize.height) / 2,
                          width: imageSize.width, height: imageSize.height)
        // Paint only the visible checkerboard, even when viewing a huge source at 100%.
        let visible = dirtyRect.intersection(rect)
        if !visible.isEmpty {
            let tile: CGFloat = 12
            for row in Int(floor(visible.minY / tile))...Int(floor(visible.maxY / tile)) {
                for col in Int(floor(visible.minX / tile))...Int(floor(visible.maxX / tile)) {
                    ((row + col) % 2 == 0 ? NSColor(white: 0.82, alpha: 1) : NSColor(white: 0.94, alpha: 1)).setFill()
                    NSRect(x: CGFloat(col) * tile, y: CGFloat(row) * tile, width: tile, height: tile).intersection(rect).fill()
                }
            }
        }
        NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            .draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }
}

/// Each visible pane owns one bounded decode. Hidden tabs retain no decoded image.
final class ImagePreviewView: NSView {
    private static let queue: OperationQueue = {
        let queue = OperationQueue(); queue.name = "SourceEditor.ImageDecode"
        queue.maxConcurrentOperationCount = 2; queue.qualityOfService = .userInitiated; return queue
    }()
    private let canvas = ImageCanvas()
    private let scroll = NSScrollView()
    private let toolbar = NSStackView()
    private let info = NSTextField(labelWithString: "Loading image…")
    private let zoom = NSTextField(labelWithString: "Fit")
    private var decode: ImageDecodeOperation?
    private var asset: EditorImageAsset?
    private var fit = true
    private(set) var scale: CGFloat = 1
    private(set) var decodedPixelSize = NSSize.zero
    private(set) var loading = false
    var onFocus: (() -> Void)?
    var onReload: (() -> Void)?
    var onExitFocus: (() -> Bool)?
    var makeFileMenu: (() -> NSMenu?)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { onFocus?(); return true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("editor.imagePreview")
        clipsToBounds = true
        toolbar.orientation = .horizontal; toolbar.spacing = 6
        func button(_ label: String, _ selector: Selector, _ id: String) -> NSButton {
            let button = NSButton(title: label, target: self, action: selector)
            button.bezelStyle = .rounded; button.controlSize = .small
            button.identifier = NSUserInterfaceItemIdentifier("image." + id)
            return button
        }
        for button in [button("−", #selector(zoomOut), "zoomOut"), button("+", #selector(zoomIn), "zoomIn"),
                       button("Fit", #selector(fitToWindow), "fit"), button("100%", #selector(actualSize), "actual"),
                       button("Reload", #selector(reload), "reload")] { toolbar.addArrangedSubview(button) }
        zoom.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        zoom.setContentCompressionResistancePriority(.required, for: .horizontal)
        toolbar.addArrangedSubview(zoom)
        info.font = NSFont.systemFont(ofSize: 11); info.lineBreakMode = .byTruncatingTail
        info.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toolbar.addArrangedSubview(info)
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.documentView = canvas
        canvas.activate = { [weak self] in guard let self else { return }; self.window?.makeFirstResponder(self) }
        canvas.context = { [weak self] in self?.contextMenu() }
        addSubview(scroll); addSubview(toolbar)
        updateTheme()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { decode?.cancel() }
    func updateTheme() {
        scroll.backgroundColor = EditorTheme.background
        info.textColor = EditorTheme.muted; zoom.textColor = EditorTheme.foreground
        canvas.needsDisplay = true
    }
    func update(_ value: EditorImageAsset, force: Bool = false) {
        guard force || asset != value else { updateTheme(); return }
        asset = value; decode?.cancel(); canvas.image = nil; decodedPixelSize = .zero
        loading = true; info.stringValue = "Loading · " + value.summary; info.toolTip = value.url.path
        needsLayout = true
        let work = ImageDecodeOperation(value); decode = work
        work.completionBlock = { [weak self, weak work] in
            guard let work, !work.isCancelled, let result = work.result else { return }
            DispatchQueue.main.async { [weak self, weak work] in
                guard let self, let work, self.decode === work, !work.isCancelled else { return }
                self.decode = nil; self.loading = false
                switch result {
                case .success(let image):
                    self.canvas.image = image; self.decodedPixelSize = NSSize(width: image.width, height: image.height)
                    self.info.stringValue = value.summary
                    if max(value.width, value.height) > EditorImageAsset.thumbnailEdge { self.info.stringValue += " · Reduced-resolution preview" }
                case .failure(let error): self.info.stringValue = error.localizedDescription
                }
                self.info.toolTip = self.info.stringValue + "\n" + value.url.path
                self.needsLayout = true
            }
        }
        Self.queue.addOperation(work)
    }
    override func layout() {
        super.layout()
        toolbar.frame = NSRect(x: 8, y: 4, width: max(1, bounds.width - 16), height: 28)
        scroll.frame = NSRect(x: 0, y: 36, width: bounds.width, height: max(1, bounds.height - 36))
        guard let asset else { return }
        let viewport = scroll.contentView.bounds.size
        if fit { scale = min(1, min(max(1, viewport.width - 24) / CGFloat(asset.width), max(1, viewport.height - 24) / CGFloat(asset.height))) }
        canvas.imageSize = NSSize(width: CGFloat(asset.width) * scale, height: CGFloat(asset.height) * scale)
        canvas.setFrameSize(NSSize(width: max(viewport.width, canvas.imageSize.width + 24), height: max(viewport.height, canvas.imageSize.height + 24)))
        zoom.stringValue = (fit ? "Fit · " : "") + String(format: "%.0f%%", scale * 100)
        canvas.needsDisplay = true
    }
    private func setScale(_ value: CGFloat, fit: Bool = false) {
        window?.makeFirstResponder(self)
        self.fit = fit; scale = min(8, max(0.01, value))
        needsLayout = true; layoutSubtreeIfNeeded()
    }
    @objc func zoomIn() { setScale(scale * 1.25) }
    @objc func zoomOut() { setScale(scale / 1.25) }
    @objc func fitToWindow() { setScale(scale, fit: true) }
    @objc func actualSize() { setScale(1) }
    @objc private func reload() { window?.makeFirstResponder(self); onReload?() }
    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "+", "=": zoomIn()
        case "-": zoomOut()
        case "0": fitToWindow()
        case "1": actualSize()
        case "\u{1b}": if onExitFocus?() != true { super.keyDown(with: event) }
        default: super.keyDown(with: event)
        }
    }
    override func magnify(with event: NSEvent) { setScale(scale * (1 + event.magnification)) }
    override func menu(for event: NSEvent) -> NSMenu? { window?.makeFirstResponder(self); return contextMenu() }
    private func contextMenu() -> NSMenu {
        let menu = makeFileMenu?() ?? NSMenu(title: "Image")
        menu.addItem(.separator())
        for (label, action) in [("Fit Image", #selector(fitToWindow)), ("Actual Size", #selector(actualSize)),
                                ("Zoom In", #selector(zoomIn)), ("Zoom Out", #selector(zoomOut)), ("Reload Image", #selector(reload))] {
            let item = NSMenuItem(title: label, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        return menu
    }
}
