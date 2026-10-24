import AppKit
import WebKit

enum MarkdownViewMode: Int {
    case edit, preview, sideBySide
}

private final class MarkdownRenderOperation: Operation {
    let text: String
    let title: String
    let fileURL: URL?
    let projectURL: URL?
    let light: Bool
    var result: Result<MarkdownPage, Error>?
    init(text: String, title: String, fileURL: URL?, projectURL: URL?, light: Bool) {
        self.text = text; self.title = title; self.fileURL = fileURL; self.projectURL = projectURL; self.light = light
    }
    override func main() {
        guard !isCancelled else { return }
        autoreleasepool {
            result = Result { try MarkdownRenderer.render(text, title: title, documentURL: fileURL,
                projectURL: projectURL, light: light, isCancelled: { self.isCancelled }) }
        }
    }
}

/// One preview owns one bounded serial render queue. Requests retain text snapshots,
/// never documents. Generation checks discard completed work after tab changes.
final class MarkdownPreviewView: NSView, WKNavigationDelegate {
    private struct Key: Equatable {
        let document: ObjectIdentifier
        let revision: UInt64
        let file: URL?
        let project: URL?
        let title: String
        let light: Bool
    }
    let webView: WKWebView
    private let notice = NSTextField(labelWithString: "Rendering Markdown…")
    private let queue = OperationQueue()
    private var debounce: Timer?
    private var operation: MarkdownRenderOperation?
    private var key: Key?
    private var generation = 0
    private var pendingScroll: Double = 0
    private(set) var page: MarkdownPage?
    private(set) var isRendering = false
    private(set) var renderedRevision: UInt64?
    var didRender: (() -> Void)?
    var openFile: ((URL) -> Void)?
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: frame)
        queue.name = "SourceEditor.Markdown"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        webView.navigationDelegate = self
        webView.underPageBackgroundColor = EditorTheme.background
        notice.font = .systemFont(ofSize: 12)
        notice.textColor = EditorTheme.muted
        notice.setAccessibilityLabel("Markdown preview status")
        webView.setAccessibilityLabel("Rendered Markdown")
        addSubview(webView)
        addSubview(notice)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { debounce?.invalidate(); queue.cancelAllOperations() }

    override func layout() {
        super.layout()
        let top: CGFloat = notice.isHidden ? 0 : 30
        notice.frame = NSRect(x: 14, y: 5, width: max(1, bounds.width - 28), height: 20)
        webView.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(1, bounds.height - top))
    }

    func update(document: EditorDocument, projectURL: URL?, light: Bool, immediately: Bool = false) {
        let next = Key(document: ObjectIdentifier(document), revision: document.revision, file: document.fileURL,
                       project: projectURL, title: document.displayName, light: light)
        guard next != key else { return }
        let sameDocument = key?.document == next.document
        key = next
        generation += 1
        let currentGeneration = generation
        debounce?.invalidate()
        queue.cancelAllOperations()
        page = nil
        renderedRevision = nil
        isRendering = true
        notice.stringValue = "Rendering Markdown…"
        notice.isHidden = false
        needsLayout = true
        if !sameDocument { pendingScroll = 0; webView.loadHTMLString("", baseURL: nil) }
        guard document.storage.length <= MarkdownRenderer.maximumUTF16 else {
            showError("This document exceeds the Markdown preview limit. Use Edit to continue.")
            return
        }
        let request = MarkdownRenderOperation(text: document.storage.string, title: next.title,
            fileURL: next.file, projectURL: projectURL, light: light)
        operation = request
        request.completionBlock = { [weak self, weak request] in
            guard let result = request?.result, request?.isCancelled == false else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == currentGeneration, self.key == next else { return }
                self.isRendering = false
                switch result {
                case .success(let page):
                    self.page = page
                    self.renderedRevision = next.revision
                    self.notice.isHidden = true
                    self.needsLayout = true
                    self.webView.underPageBackgroundColor = light ? .white : EditorTheme.background
                    func load(_ scroll: Double) {
                        guard self.generation == currentGeneration else { return }
                        self.pendingScroll = sameDocument ? scroll : 0
                        self.webView.loadHTMLString(page.html, baseURL: nil)
                    }
                    if sameDocument {
                        self.webView.evaluateJavaScript("window.scrollY / Math.max(1, document.documentElement.scrollHeight - innerHeight)") { value, _ in
                            load(min(1, max(0, (value as? Double) ?? 0)))
                        }
                    } else { load(0) }
                case .failure(let error): self.showError(error.localizedDescription)
                }
                self.didRender?()
            }
        }
        // An explicit first preview/tab switch should start immediately. Only
        // repeated edits of the same document need the typing debounce.
        if immediately || !sameDocument { queue.addOperation(request) }
        else {
            debounce = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self, weak request] _ in
                guard let self, let request, self.generation == currentGeneration else { return }
                self.queue.addOperation(request)
            }
        }
        didRender?()
    }

    private func showError(_ message: String) {
        isRendering = false
        page = nil
        notice.stringValue = message
        notice.isHidden = false
        webView.loadHTMLString("", baseURL: nil)
        needsLayout = true
        didRender?()
    }

    func showHeading(_ heading: MarkdownHeading) {
        guard let data = try? JSONEncoder().encode(heading.anchor), let anchor = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("document.getElementById(\(anchor))?.scrollIntoView({block:'start'})", completionHandler: nil)
    }

    func stop() {
        generation += 1
        key = nil
        debounce?.invalidate()
        debounce = nil
        queue.cancelAllOperations()
        operation = nil
        webView.stopLoading()
        page = nil
        didRender = nil
        openFile = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if pendingScroll > 0 {
            webView.evaluateJavaScript("window.scrollTo(0, Math.max(0,document.documentElement.scrollHeight-innerHeight)*\(pendingScroll))", completionHandler: nil)
        }
        pendingScroll = 0
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if navigationAction.navigationType != .linkActivated {
            decisionHandler(url.scheme == "about" ? .allow : .cancel)
            return
        }
        if url.scheme == "about", url.fragment != nil { decisionHandler(.allow); return }
        decisionHandler(.cancel)
        if url.scheme == "source-editor-link", let file = page?.localLinks[url.lastPathComponent] { openFile?(file) }
        else if ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        key = nil
        showError("The preview stopped. Switch to Edit and reopen Preview to reload it.")
    }
}
