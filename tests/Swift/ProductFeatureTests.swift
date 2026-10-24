import AppKit

enum ProductFeatureTests {
    static func writeAbruptRecovery(directory: URL) -> Never {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("original.txt")
            try "disk original".write(to: file, atomically: true, encoding: .utf8)
            let document = try EditorDocument.open(file)
            document.setTextUndoably("unsaved recovery 中文😀", actionName: "Fixture")
            let owner = EditorRecovery(directory: directory)
            let session = EditorSession(selectedIndex: 0, split: false, documents: [.init(document: document, ranges: [.init(location: 3, length: 0)])])
            owner.write(session) { error in
                if let error { fputs(error.localizedDescription, stderr); exit(1) }
                print(owner.url.path); fflush(stdout)
                _exit(86) // No window-close, termination or recovery cleanup callbacks.
            }
            RunLoop.current.run()
        } catch { fputs(error.localizedDescription, stderr) }
        exit(1)
    }
    static func readAbruptRecovery(_ url: URL) -> Int32 {
        do {
            let session = try EditorSession.load(url)
            let restored = session.documents[0].restore()
            let ok = restored.0.storage.string == "unsaved recovery 中文😀" && restored.0.isModified && restored.0.fileURL == nil && restored.1 == [.init(location: 3, length: 0)]
            print("{\"ok\":\(ok),\"passed\":\(ok ? 1 : 0)}")
            return ok ? 0 : 1
        } catch { fputs(error.localizedDescription, stderr); return 1 }
    }
    static func run() -> Int32 {
        var passed = 0, failures: [String] = []
        func check(_ name: String, _ value: Bool) { if value { passed += 1 } else { failures.append(name) } }
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("source-editor-product-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("readme.md")
            let source = """
            # 标题 😀

            Hello **strong** and *emphasis* with `inline` and ~~deleted~~.

            ## Nested

            - one
              - two

            > quoted

            ```swift
            let value = "<tag>"
            ```

            | Left | Right |
            | :--- | ---: |
            | a | b |

            - [x] done
            - [ ] todo

            [link](https://example.com) [local](other.md)

            ![pixel](pixel.png)
            """
            let pixel = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==")!
            try pixel.write(to: directory.appendingPathComponent("pixel.png"))
            let page = try MarkdownRenderer.render(source, title: "A <title>", documentURL: file)
            check("Semantic headings and source lines", page.headings.count == 2 && page.headings[0].title == "标题 😀" && page.headings[1].line == 5)
            check("Inline markup", page.html.contains("<strong>strong</strong>") && page.html.contains("<em>emphasis</em>") && page.html.contains("<del>deleted</del>"))
            check("Code is escaped", page.html.contains("&lt;tag&gt;") && page.html.contains("<figcaption>swift</figcaption>"))
            check("Nested lists and quote", page.html.components(separatedBy: "<ul>").count >= 3 && page.html.contains("<blockquote>"))
            check("Table alignment", page.html.contains("<th style=\"text-align:right\">Right</th>"))
            check("Tasks are disabled controls", page.html.contains("disabled checked") && page.html.contains("aria-label=\"Task\""))
            check("Images embedded locally", page.html.contains("data:image/png;base64,") && page.html.contains("alt=\"pixel\""))
            var largeImage = pixel
            largeImage.append(Data(count: 3 * 1024 * 1024))
            try largeImage.write(to: directory.appendingPathComponent("repeated.png"))
            let repeated = try MarkdownRenderer.render(String(repeating: "![repeat](repeated.png)\n\n", count: 20), title: "Images", documentURL: file)
            check("Repeated image references obey output budget", repeated.html.contains("Image embedding limit") && repeated.html.components(separatedBy: "data:image/png;base64,").count <= 5 && repeated.html.utf8.count <= MarkdownRenderer.maximumHTMLBytes)
            check("External links and native local routing", page.html.contains("href=\"https://example.com\"") && page.localLinks.values.contains(directory.appendingPathComponent("other.md")))
            check("Export uses browser file links", !page.exportHTML.contains("source-editor-link:") && page.exportHTML.contains("other.md"))
            check("Title and page policy", page.html.contains("A &lt;title&gt;") && page.html.contains("script-src 'none'"))
            check("Word count", page.wordCount > 10)
            let unsafe = try MarkdownRenderer.render("<script>alert(1)</script>\n\n[x] prose\n\n[bad](javascript:alert(1))\n\n![outside](../outside.png)", title: "X", documentURL: file)
            check("Raw HTML is text", !unsafe.html.contains("<script>") && unsafe.html.contains("&lt;script&gt;"))
            check("Unsafe link omitted", !unsafe.html.contains("href=\"javascript:"))
            check("Tasks only in list paragraphs", !unsafe.html.contains("type=\"checkbox\""))
            check("Outside images omitted", unsafe.html.contains("Image: outside"))
            let duplicate = try MarkdownRenderer.render("# A\n# A\n# A-1\n# A", title: "X", documentURL: file)
            check("Collision-free heading anchors", Set(duplicate.headings.map(\.anchor)).count == 4)
            let light = try MarkdownRenderer.render("# A", title: "X", documentURL: nil, light: true)
            check("Light theme", light.html.contains("data-theme=\"light\""))
            let boundedFile = directory.appendingPathComponent("bounded.bin")
            try Data(repeating: 65, count: 17).write(to: boundedFile)
            do { _ = try LocalFileData.read(boundedFile, maximumBytes: 16); check("Read limit before allocation", false) }
            catch { check("Read limit before allocation", true) }
            check("Read at exact byte limit", (try? LocalFileData.read(boundedFile, maximumBytes: 17))?.count == 17)
            let empty = try MarkdownRenderer.render("", title: "X", documentURL: nil)
            check("Empty page", empty.html.contains("Start writing Markdown") && empty.headings.isEmpty)
            do { _ = try MarkdownRenderer.render(String(repeating: "x", count: MarkdownRenderer.maximumUTF16 + 1), title: "X", documentURL: nil); check("Preview capacity", false) }
            catch { check("Preview capacity", true) }
            do { _ = try MarkdownRenderer.render("# A", title: "X", documentURL: nil, isCancelled: { true }); check("Cancelled parse", false) }
            catch is CancellationError { check("Cancelled parse", true) }
            check("Markdown extension aliases", ["md", "markdown", "mdown", "mkd"].allSatisfy { EditorSyntax.resolve($0) == .markdown })
            try "prefix 😀\r\nNeedle first\r\nneedle second\n".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try Data([0, 1, 2, 3]).write(to: directory.appendingPathComponent("binary"))
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
            try "needle".write(to: directory.appendingPathComponent("node_modules/ignored.txt"), atomically: true, encoding: .utf8)
            let found = ProjectSearchEngine.search(root: directory, query: "needle", caseSensitive: false)
            check("Project search Unicode and CRLF lines", found.hits.count == 2 && found.hits.map(\.line) == [2, 3] && found.hits[0].range.location == 11)
            check("Project search exact source match", found.hits.map(\.matchedText) == ["Needle", "needle"])
            check("Project search binary and dependencies omitted", found.skippedFiles >= 1 && !found.hits.contains { $0.file.path.contains("node_modules") })
            check("Case-sensitive project search", ProjectSearchEngine.search(root: directory, query: "Needle", caseSensitive: true).hits.count == 1)
            check("Project cancellation", ProjectSearchEngine.search(root: directory, query: "needle", caseSensitive: false, isCancelled: { true }).scan.cancelled)
            try String(repeating: "match\n", count: 2_100).write(to: directory.appendingPathComponent("many.txt"), atomically: true, encoding: .utf8)
            let capped = ProjectSearchEngine.search(root: directory, query: "match", caseSensitive: true)
            check("Match cap explicit", capped.hits.count == 2_000 && capped.limitReason == "2,000 match limit")
            try Data(repeating: 65, count: ProjectSearchEngine.maximumFileBytes + 1).write(to: directory.appendingPathComponent("large.txt"))
            let large = ProjectSearchEngine.search(root: directory, query: "never-match", caseSensitive: true)
            check("Large files not read", large.readBytes <= 30_000 && large.hits.isEmpty && large.skippedFiles >= 2 && !large.scan.limited)
            let index = ProjectIndexOperation(directory); index.start()
            let expectedFile = directory.appendingPathComponent("a.txt").standardizedFileURL
            check("Shared project scan excludes dependencies", !index.files.contains { $0.path.contains("node_modules") } && index.files.contains { $0.standardizedFileURL == expectedFile })
            let cancelled = ProjectIndexOperation(directory); cancelled.cancel(); cancelled.start()
            check("Cancelled index empty", cancelled.files.isEmpty)
            let lines = "α😀\r\n中文\r\nlast"
            let caret = NSRange(location: 7, length: 0)
            let duplicateLine = TextOperations.editLines(in: lines, selections: [caret, caret], action: .duplicate)
            check("Duplicate deduplicates lines and preserves CRLF", duplicateLine.text == "α😀\r\n中文\r\n中文\r\nlast" && duplicateLine.selections[0].location == 11)
            let lastLine = TextOperations.editLines(in: "a\r\nb", selections: [NSRange(location: 3, length: 0)], action: .duplicate, ending: .crlf)
            check("Duplicate unterminated last line", lastLine.text == "a\r\nb\r\nb" && lastLine.selections.first?.location == 6)
            let removed = TextOperations.editLines(in: lines, selections: [NSRange(location: 5, length: 4)], action: .delete)
            check("Delete logical line excludes next line endpoint", removed.text == "α😀\r\nlast")
            let up = TextOperations.editLines(in: lines, selections: [caret], action: .moveUp)
            check("Move Unicode line and cursor", up.text == "中文\r\nα😀\r\nlast" && up.selections.first?.location == 2)
            let down = TextOperations.editLines(in: "a\n😀", selections: [NSRange(location: 2, length: 2)], action: .moveUp)
            check("Move EOF text retains missing newline and selected emoji", down.text == "😀\na" && down.selections.first == NSRange(location: 0, length: 2))
            let mixed = TextOperations.editLines(in: "first\r\n😀\nx", selections: [NSRange(location: 7, length: 2)], action: .moveUp)
            check("Mixed terminators preserve positions", mixed.text == "😀\r\nfirst\nx" && mixed.selections.first == NSRange(location: 0, length: 2))
            check("Top-line move is unchanged", TextOperations.editLines(in: lines, selections: [.init(location: 0, length: 0)], action: .moveUp).text == lines)
            check("Invalid surrogate boundary rejected", TextOperations.editLines(in: "😀", selections: [.init(location: 1, length: 0)], action: .delete).error != nil)
            for syntax in [EditorSyntax.swift, .python, .sql, .css, .markdown] {
                let content = "  中文😀\r\n\tsecond\r\n\r\n"
                let selections = [NSRange(location: 0, length: content.utf16.count)]
                let commented = TextOperations.toggleComment(in: content, selections: selections, syntax: syntax)
                let restored = TextOperations.toggleComment(in: commented.text, selections: commented.selections, syntax: syntax)
                check("Comment round trip " + syntax.rawValue, commented.error == nil && commented.text != content && restored.text == content)
            }
            let commentCaret = TextOperations.toggleComment(in: "  let x = 1", selections: [.init(location: 6, length: 0)], syntax: .swift)
            check("Comment retains cursor in source text", commentCaret.text == "  // let x = 1" && commentCaret.selections.first?.location == 9)
            check("JSON comment prohibited", TextOperations.toggleComment(in: "{}", selections: [.init(location: 0, length: 0)], syntax: .json).error != nil)
            check("Block delimiter error retains input", TextOperations.toggleComment(in: "a */ b", selections: [.init(location: 0, length: 0)], syntax: .css).error != nil)
        } catch { failures.append(error.localizedDescription) }
        let result: [String: Any] = ["passed": passed, "failed": failures.count, "failures": failures]
        print(String(data: try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
        return failures.isEmpty ? 0 : 1
    }
}
