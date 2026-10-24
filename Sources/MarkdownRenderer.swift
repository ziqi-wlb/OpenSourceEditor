import Foundation
import ImageIO

struct MarkdownHeading: Equatable {
    let title: String
    let level: Int
    let line: Int
    let anchor: String
}

struct MarkdownPage {
    let html: String
    let headings: [MarkdownHeading]
    let wordCount: Int
    let localLinks: [String: URL]
    var exportHTML: String {
        var output = html
        for (token, url) in localLinks {
            output = output.replacingOccurrences(of: "href=\"source-editor-link://open/\(token)\"", with: "href=\"\(MarkdownRenderer.escape(url.absoluteString))\"")
        }
        return output
    }
}

/// Foundation owns Markdown parsing. This adapter consumes its block identities,
/// inline attributes and source positions; it does not parse Markdown a second time.
enum MarkdownRenderer {
    static let maximumUTF16 = 2_000_000
    static let maximumImageBytes = 4 * 1024 * 1024
    static let maximumTotalImageBytes = 12 * 1024 * 1024
    static let maximumEmbeddedBytes = 16 * 1024 * 1024
    static let maximumHTMLBytes = 32 * 1024 * 1024

    private final class Block {
        let kind: PresentationIntent.Kind?
        var children: [Block] = []
        var fragments: [String] = []
        var text = ""
        var line = 1
        init(_ kind: PresentationIntent.Kind? = nil) { self.kind = kind }
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    static func render(_ text: String, title: String, documentURL: URL?, projectURL: URL? = nil,
                       light: Bool = false, isCancelled: () -> Bool = { false }) throws -> MarkdownPage {
        guard (text as NSString).length <= maximumUTF16 else {
            throw EditorFailure.invalidEdit("Markdown preview supports up to 2,000,000 UTF16 units. Edit the larger file in source mode.")
        }
        if isCancelled() { throw CancellationError() }
        var options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        options.appliesSourcePositionAttributes = true
        let parsed = try AttributedString(markdown: text, options: options)
        let root = Block()
        var blocks: [Int: Block] = [:]
        var localLinks: [String: URL] = [:]
        var imageBytes = 0
        var embeddedBytes = 0
        var imageCache: [URL: String] = [:]
        var words = 0, inWord = false
        var previousBlock: Block?
        let directory = documentURL?.deletingLastPathComponent()
        let assetRoot = (projectURL ?? directory)?.standardizedFileURL.resolvingSymlinksInPath()

        func localURL(_ url: URL) -> URL? {
            guard url.scheme == nil || url.isFileURL, let directory, let assetRoot else { return nil }
            let resolved = url.isFileURL ? url : URL(string: url.relativeString, relativeTo: directory)?.absoluteURL
            guard let candidate = resolved?.standardizedFileURL.resolvingSymlinksInPath(), candidate.isFileURL,
                  candidate.pathComponents.starts(with: assetRoot.pathComponents) else { return nil }
            return candidate
        }

        func image(_ url: URL, alt: String) -> String {
            guard let file = localURL(url) else { return "<span class=\"image-placeholder\">Image: \(escape(alt))</span>" }
            if let cached = imageCache[file] {
                guard cached.utf8.count <= maximumEmbeddedBytes - embeddedBytes else { return "<span class=\"image-placeholder\">Image embedding limit: \(escape(alt))</span>" }
                embeddedBytes += cached.utf8.count
                return "<img src=\"\(cached)\" alt=\"\(escape(alt))\" loading=\"lazy\">"
            }
            let types = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"]
            guard let mime = types[file.pathExtension.lowercased()],
                  let size = (try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])), size.isRegularFile == true,
                  let count = size.fileSize, count <= maximumImageBytes, count <= maximumTotalImageBytes - imageBytes,
                  let data = try? LocalFileData.read(file, maximumBytes: maximumImageBytes),
                  data.count <= maximumTotalImageBytes - imageBytes,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 40_000_000 / height else {
                return "<span class=\"image-placeholder\">Image unavailable: \(escape(alt))</span>"
            }
            imageBytes += data.count
            let encoded = "data:\(mime);base64," + data.base64EncodedString()
            guard encoded.utf8.count <= maximumEmbeddedBytes - embeddedBytes else { return "<span class=\"image-placeholder\">Image embedding limit: \(escape(alt))</span>" }
            embeddedBytes += encoded.utf8.count
            imageCache[file] = encoded
            return "<img src=\"\(encoded)\" alt=\"\(escape(alt))\" loading=\"lazy\">"
        }

        var runCount = 0
        for run in parsed.runs {
            if isCancelled() { throw CancellationError() }
            runCount += 1
            guard runCount <= 100_000 else { throw EditorFailure.invalidEdit("Markdown has too many styled fragments to preview. Use Edit to continue.") }
            var parent = root
            let path = Array(run.presentationIntent?.components.reversed() ?? [])
            guard path.count <= 128 else { throw EditorFailure.invalidEdit("Markdown nesting is too deep to preview.") }
            for component in path {
                if let existing = blocks[component.identity] { parent = existing }
                else {
                    guard blocks.count < 100_000 else { throw EditorFailure.invalidEdit("Markdown has too many blocks to preview. Use Edit to continue.") }
                    let block = Block(component.kind)
                    block.line = run.markdownSourcePosition?.startLine ?? 1
                    parent.children.append(block)
                    blocks[component.identity] = block
                    parent = block
                }
            }
            let content = String(parsed[run.range].characters)
            if previousBlock !== parent { inWord = false }
            previousBlock = parent
            for scalar in content.unicodeScalars {
                let cjk = (0x3400...0x9fff).contains(scalar.value)
                if cjk { words += 1; inWord = false }
                else if CharacterSet.alphanumerics.contains(scalar) { if !inWord { words += 1 }; inWord = true }
                else { inWord = false }
            }
            parent.text += content
            let intent = run.inlinePresentationIntent ?? []
            var inline = escape(content)
            if intent.contains(.lineBreak) { inline = "<br>" }
            if intent.contains(.code) { inline = "<code>\(inline)</code>" }
            if intent.contains(.stronglyEmphasized) { inline = "<strong>\(inline)</strong>" }
            if intent.contains(.emphasized) { inline = "<em>\(inline)</em>" }
            if intent.contains(.strikethrough) { inline = "<del>\(inline)</del>" }
            if let url = run.imageURL { inline = image(url, alt: content) }
            else if let url = run.link {
                var target: String?
                if url.relativeString.hasPrefix("#") { target = url.relativeString }
                else if ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { target = url.absoluteString }
                else if let local = localURL(url) {
                    let token = String(localLinks.count)
                    localLinks[token] = local
                    target = "source-editor-link://open/\(token)"
                }
                if let target { inline = "<a href=\"\(escape(target))\">\(inline)</a>" }
            }
            parent.fragments.append(inline)
        }

        var headings: [MarkdownHeading] = []
        var anchors: [String: Int] = [:]
        var usedAnchors = Set<String>()
        func html(_ block: Block, headerRow: Bool = false, listParagraph: Bool = false,
                  columns: [PresentationIntent.TableColumn] = []) throws -> String {
            if isCancelled() { throw CancellationError() }
            let tableColumns: [PresentationIntent.TableColumn]
            if case .table(let values) = block.kind { tableColumns = values } else { tableColumns = columns }
            let children = try block.children.map {
                let isListItem: Bool
                if case .listItem = block.kind { isListItem = true } else { isListItem = false }
                return try html($0, headerRow: block.kind == .tableHeaderRow, listParagraph: isListItem, columns: tableColumns)
            }
            let contentBytes = block.fragments.reduce(0) { $0 + $1.utf8.count } + children.reduce(0) { $0 + $1.utf8.count }
            guard contentBytes <= maximumHTMLBytes - 1024 else { throw EditorFailure.invalidEdit("Rendered Markdown exceeds the 32 MiB HTML limit.") }
            let contents = block.fragments.joined() + children.joined()
            switch block.kind {
            case .paragraph:
                // Foundation leaves task markers as literal text in list paragraphs.
                if listParagraph && (block.text.hasPrefix("[ ] ") || block.text.hasPrefix("[x] ") || block.text.hasPrefix("[X] ")) {
                    let checked = !block.text.hasPrefix("[ ] ")
                    let marker = escape(String(block.text.prefix(4)))
                    let rest = contents.hasPrefix(marker) ? String(contents.dropFirst(marker.count)) : contents
                    return "<p class=\"task\"><input type=\"checkbox\" disabled\(checked ? " checked" : "") aria-label=\"Task\">\(rest)</p>"
                }
                return "<p>\(contents)</p>"
            case .header(let level):
                let base = block.text.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }
                    .joined().split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
                let slug = base.isEmpty ? "section" : base
                var occurrence = anchors[slug, default: 0]
                var anchor = occurrence == 0 ? slug : slug + "-" + String(occurrence)
                while usedAnchors.contains(anchor) { occurrence += 1; anchor = slug + "-" + String(occurrence) }
                anchors[slug] = occurrence + 1
                usedAnchors.insert(anchor)
                headings.append(MarkdownHeading(title: block.text, level: level, line: block.line, anchor: anchor))
                return "<h\(level) id=\"\(escape(anchor))\">\(contents)</h\(level)>"
            case .orderedList: return "<ol>\(contents)</ol>"
            case .unorderedList: return "<ul>\(contents)</ul>"
            case .listItem(let ordinal): return "<li value=\"\(ordinal)\">\(contents)</li>"
            case .codeBlock(let language):
                return "<figure class=\"code-block\"><figcaption>\(escape(language ?? "code"))</figcaption><pre><code>\(escape(block.text))</code></pre></figure>"
            case .blockQuote: return "<blockquote>\(contents)</blockquote>"
            case .thematicBreak: return "<hr>"
            case .table: return "<div class=\"table-wrap\"><table>\(contents)</table></div>"
            case .tableHeaderRow, .tableRow: return "<tr>\(contents)</tr>"
            case .tableCell(let column):
                let alignment = columns.indices.contains(column) ? columns[column].alignment : .left
                let value = alignment == .right ? "right" : alignment == .center ? "center" : "left"
                return "<\(headerRow ? "th" : "td") style=\"text-align:\(value)\">\(contents)</\(headerRow ? "th" : "td")>"
            case nil: return contents
            @unknown default: return "<div>\(contents)</div>"
            }
        }
        let body = try html(root)
        let contents = headings.map { "<a class=\"depth-\($0.level)\" href=\"#\(escape($0.anchor))\">\(escape($0.title))</a>" }.joined()
        let toc = headings.isEmpty ? "" : "<details class=\"contents\"><summary>Contents</summary><nav>\(contents)</nav></details>"
        let theme = light ? "light" : "dark"
        guard body.utf8.count + toc.utf8.count + title.utf8.count * 6 + css.utf8.count + 1024 <= maximumHTMLBytes else {
            throw EditorFailure.invalidEdit("Rendered Markdown exceeds the 32 MiB HTML limit.")
        }
        let page = """
        <!doctype html><html lang="en" data-theme="\(theme)"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src 'none'; base-uri 'none'; form-action 'none'">
        <title>\(escape(title))</title><style>\(css)</style></head><body><main>\(toc)\(body.isEmpty ? "<p class=\"empty\">Start writing Markdown to see your document here.</p>" : body)</main></body></html>
        """
        return MarkdownPage(html: page, headings: headings, wordCount: words, localLinks: localLinks)
    }

    private static let css = """
    :root{color-scheme:dark;--bg:#171c25;--fg:#dbe4ee;--muted:#9aa9bc;--border:#344151;--panel:#222b38;--accent:#71c5f3}
    html[data-theme=light]{color-scheme:light;--bg:#fff;--fg:#263445;--muted:#64758a;--border:#dce3ec;--panel:#f2f5f9;--accent:#086baf}
    *{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.75 -apple-system,BlinkMacSystemFont,sans-serif}
    main{max-width:880px;margin:auto;padding:30px 38px 90px;overflow-wrap:anywhere}h1,h2,h3,h4,h5,h6{line-height:1.3;margin:1.6em 0 .65em;scroll-margin:24px}
    h1{font-size:2em;border-bottom:1px solid var(--border);padding-bottom:.4em}h2{font-size:1.5em;border-bottom:1px solid var(--border);padding-bottom:.3em}h3{font-size:1.2em}
    p{margin:.8em 0}a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}blockquote{margin:1em 0;border-left:4px solid var(--accent);padding:.1em 1.2em;color:var(--muted);background:var(--panel);border-radius:0 6px 6px 0}
    code{font:13px/1.6 ui-monospace,SFMono-Regular,Menlo,monospace;background:var(--panel);padding:.15em .4em;border-radius:4px}pre{margin:0;overflow:auto;padding:16px}pre code{padding:0;background:none;white-space:pre;overflow-wrap:normal}
    figure.code-block{margin:1em 0;background:var(--panel);border:1px solid var(--border);border-radius:8px;overflow:hidden}figcaption{font-size:11px;color:var(--muted);padding:5px 16px;border-bottom:1px solid var(--border)}
    ul,ol{padding-left:1.7em}li>p{margin:.25em 0}.task input{margin-right:8px;accent-color:var(--accent)}hr{border:0;border-top:1px solid var(--border);margin:2em 0}
    .table-wrap{overflow-x:auto;margin:1em 0}table{border-collapse:collapse;width:100%;font-size:14px}th,td{border:1px solid var(--border);padding:8px 12px;text-align:left}th{background:var(--panel)}tr:nth-child(even){background:var(--panel)}
    img{max-width:100%;height:auto;border-radius:6px}.image-placeholder,.empty{color:var(--muted)}.image-placeholder{display:inline-block;padding:10px;border:1px dashed var(--border);border-radius:6px}
    .contents{border:1px solid var(--border);border-radius:8px;padding:10px 16px;font-size:13px;color:var(--muted)}summary{cursor:pointer}nav{display:flex;flex-direction:column;gap:4px;padding:10px 0}.depth-2{padding-left:12px}.depth-3,.depth-4,.depth-5,.depth-6{padding-left:24px}
    @media(max-width:560px){main{padding:20px 18px 60px}body{font-size:15px}}@media print{body{background:white;color:black}main{max-width:none;padding:0}.contents{display:none}pre{white-space:pre-wrap}a{color:inherit}}
    """
}
