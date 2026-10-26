import AppKit

enum DocumentSettingsTestRunner {
    static func run() -> Int32 {
        var results: [[String: Any]] = []
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("source-editor-settings-" + UUID().uuidString)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false) }
        catch { print(error); return 1 }
        defer { try? FileManager.default.removeItem(at: directory) }
        func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            if try !condition() { throw TestFailure.assertion(message) }
        }
        func rejects(_ body: () throws -> Void) throws {
            do { try body() } catch { return }
            throw TestFailure.assertion("Expected rejection")
        }
        func test(_ name: String, _ body: () throws -> Void) {
            let start = Date()
            do { try body(); results.append(["name": name, "status": "passed", "seconds": Date().timeIntervalSince(start)]) }
            catch { results.append(["name": name, "status": "failed", "error": String(describing: error), "seconds": Date().timeIntervalSince(start)]) }
        }
        func spaces(_ width: Int = 4) -> DocumentSettings {
            var value = DocumentSettings(); value.detectIndentation = false; value.translateTabsToSpaces = true; value.tabSize = width
            return value
        }
        func caret(_ position: Int) -> [NSRange] { [NSRange(location: position, length: 0)] }
        func file(_ name: String, _ bytes: Data) throws -> URL {
            let url = directory.appendingPathComponent(name); try bytes.write(to: url); return url
        }
        test("Document position preserves scalar, tab and CRLF cursor semantics") {
            func reference(_ text: String, _ offset: Int, _ width: Int) -> (Int, Int) {
                var line = 1, column = 0, previousCR = false
                let prefix = String(decoding: Array(text.utf16.prefix(offset)), as: UTF16.self)
                for scalar in prefix.unicodeScalars {
                    if scalar.value == 13 { line += 1; column = 0; previousCR = true }
                    else if scalar.value == 10 { if !previousCR { line += 1 }; column = 0; previousCR = false }
                    else { column += scalar.value == 9 ? width - column % width : 1; previousCR = false }
                }
                return (line, column + 1)
            }
            for text in ["", "a\r\nb\rc\n", "\r\n\r\r\n\n", "🙂\t甲e\u{301}\r\n\tend\n"] {
                let document = EditorDocument(text: text)
                for width in [1, 4, 8] {
                    var settings = document.settings; settings.tabSize = width; try document.updateSettings(settings)
                    for offset in 0...text.utf16.count {
                        let units = Array(text.utf16)
                        if offset > 0 && offset < units.count && UTF16.isLeadSurrogate(units[offset - 1]) && UTF16.isTrailSurrogate(units[offset]) {
                            try check(document.position(at: offset) == nil, "Split surrogate rejected")
                        } else {
                            let expected = reference(text, offset, width), actual = document.position(at: offset)
                            try check(actual?.line == expected.0 && actual?.column == expected.1, "Position \(offset) tab \(width)")
                        }
                    }
                }
                try check(document.position(at: -1) == nil && document.position(at: text.utf16.count + 1) == nil, "Range validation")
            }
        }
        test("Line index handles chunk boundary pairs and updates after native edits and undo") {
            let text = String(repeating: "x", count: 4095) + "🙂\r\n\tend\n"
            let document = EditorDocument(text: text)
            try check(document.position(at: 4097)?.column == 4097, "Surrogate across scan buffer")
            try check(document.position(at: 4098)?.line == 2 && document.position(at: 4098)?.column == 1, "Between CRLF")
            try check(document.lineIndex.starts == [0, 4099, 4104], "Logical offsets")
            document.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "a\n")
            try check(document.lineIndex.starts == [0, 2, 4101, 4106] && document.position(at: 4106)?.line == 4, "Native storage invalidation before notification")
            document.setTextUndoably("a\rb\n", actionName: "Edit")
            try check(document.position(at: 4)?.line == 3, "Replacement")
            document.undoManager.undo()
            try check(document.position(at: 4106)?.line == 4, "Undo invalidation")
            document.restoreSessionState(text: "restored\n", encoding: nil, settings: nil)
            try check(document.position(at: 9)?.line == 2, "Recovery invalidation")
        }
        test("Dirty cache preserves exact Unicode and saved baseline across undo and metadata") {
            let document = EditorDocument(text: "é\n")
            try check(!document.isModified, "Initial baseline")
            document.storage.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 0, length: 2))
            try check(!document.isModified, "Presentation attributes")
            document.setTextUndoably("e\u{301}\n", actionName: "Change normalization")
            try check(document.isModified && document.isModified, "Canonically equivalent bytes remain dirty")
            document.undoManager.undo(); try check(!document.isModified, "Undo returns to saved bytes")
            document.undoManager.redo(); document.checkpoint(); try check(!document.isModified, "New save baseline")
            document.undoManager.undo(); try check(document.isModified, "Undo across saved baseline")
            document.undoManager.redo(); try check(!document.isModified, "Redo saved text")
            document.storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "X")
            try check(document.isModified, "Direct storage change invalidates cache")
        }
        test("Viewport lexical matches retain multiline context and invalidate with text and syntax") {
            var settings = DocumentSettings(); settings.syntax = "swift"
            let body = String(repeating: "body\n", count: 1000)
            let document = EditorDocument(text: "/*\n" + body + "let value = 123\n*/\n", settings: settings)
            let offset = 3 + body.utf16.count
            let viewport = NSRange(location: offset, length: 15)
            let comments = document.syntaxHighlights.matches(in: viewport, group: 3)
            try check(comments.count == 1 && comments.first?.location == viewport.location && comments.first?.length == viewport.length, "Multiline comment intersects only the visible range")
            try check(document.syntaxHighlights.matches(in: viewport, group: 0).count == 1, "Keyword retained for comment overlay precedence")
            document.setTextUndoably("# let value = 123\n", actionName: "Edit")
            try check(document.syntaxHighlights.groups[3].isEmpty, "Text cache invalidates")
            settings.syntax = "py"; try document.updateSettings(settings)
            try check(document.syntaxHighlights.groups[3].count == 1, "Syntax cache invalidates without text revision")
            document.undoManager.undo()
            try check(document.syntaxHighlights.groups[3].isEmpty, "Undo honors currently selected syntax")
            settings.syntax = "plain"; try document.updateSettings(settings)
            try check(document.syntaxHighlights.groups.isEmpty, "Unsupported syntax has no tokens")
        }
        test("Chunked indentation preserves newline separators, blank lines and grapheme prefixes") {
            let cases = ["\tfoo\r\n\tbar\n", "  foo\u{85}    bar\u{2028}  baz", "   \r\n\t\n", " \u{301}x\n  y\n", "    a\u{B}  b\u{C}    c\u{2029}plain", String(repeating: "x", count: 4095) + "\r\n  value\n    next\n"]
            for text in cases {
                var expected = DocumentSettings(), spacesRows = 0, tabRows = 0, width = 0
                for line in text.components(separatedBy: .newlines) {
                    let prefix = line.prefix { $0 == " " || $0 == "\t" }
                    guard !prefix.isEmpty, prefix.count < line.count else { continue }
                    if prefix.contains("\t") { tabRows += 1 }
                    else {
                        spacesRows += 1
                        var x = width, y = prefix.count
                        while y != 0 { let remainder = x % y; x = y; y = remainder }
                        width = x
                    }
                }
                if spacesRows > tabRows { expected.translateTabsToSpaces = true; if width > 0 { expected.tabSize = width } }
                else if tabRows > 0 { expected.translateTabsToSpaces = false }
                try check(TextOperations.detectedIndentation(in: text, defaults: DocumentSettings()) == expected, "Streaming detection parity")
            }
        }
        for encoding in EditorEncoding.allCases {
            test("Codec ASCII round-trip: " + encoding.displayName) {
                let text = " A\tB\r\n"
                let bytes = try encoding.encode(text)
                let decoded = try EditorEncoding.decode(bytes, using: encoding)
                try check(decoded.0 == text && decoded.1 == encoding, "Codec bytes/identity")
            }
        }
        test("Unicode endian and BOM byte contracts") {
            let text = "A甲🙂\r\n"
            let little = Data([0x41, 0, 0x32, 0x75, 0x3d, 0xd8, 0x42, 0xde, 13, 0, 10, 0])
            let big = Data([0, 0x41, 0x75, 0x32, 0xd8, 0x3d, 0xde, 0x42, 0, 13, 0, 10])
            let samples: [(EditorEncoding, Data)] = [(.utf8, Data(text.utf8)), (.utf8BOM, Data([0xef, 0xbb, 0xbf]) + Data(text.utf8)),
                (.utf16LE, little), (.utf16LEBOM, Data([0xff, 0xfe]) + little), (.utf16BE, big), (.utf16BEBOM, Data([0xfe, 0xff]) + big)]
            for (codec, expected) in samples {
                try check(try codec.encode(text) == expected, "Exact endian/BOM bytes: \(codec)")
                let path = try file(codec.rawValue + ".txt", expected)
                let document = try EditorDocument.open(path, encoding: codec)
                try document.save()
                try check(document.encoding == codec && (try Data(contentsOf: path)) == expected, "Disk round-trip")
            }
        }
        test("Malformed UTF16 cannot decode with substitution") {
            for bytes in [Data([0xff, 0xfe, 0]), Data([0xff, 0xfe, 0, 0xd8]), Data([0xfe, 0xff, 0xdc, 0]), Data([0xff, 0xfe, 0, 0xd8, 0x41, 0])] {
                try rejects { _ = try EditorEncoding.decode(bytes) }
            }
        }
        test("Strict auto detection and explicit legacy decode") {
            let bytes = Data([0x63, 0x61, 0x66, 0xe9, 0x20, 0x80])
            try rejects { _ = try EditorEncoding.decode(bytes) }
            let decoded = try EditorEncoding.decode(bytes, using: .windows1252)
            try check(decoded.0 == "café €" && decoded.1 == .windows1252, "Explicit legacy decoding")
        }
        test("Legacy non-ASCII exact bytes across scripts") {
            let samples: [(EditorEncoding, String, Data)] = [(.windows1252, "é€", Data([0xe9, 0x80])),
                (.windows1251, "Я", Data([0xdf])), (.cp862, "א", Data([0x80])), (.cp865, "ø", Data([0x9b])), (.gb18030, "中", Data([0xd6, 0xd0]))]
            for (codec, text, expected) in samples {
                try check(try codec.encode(text) == expected, "Exact bytes: \(codec)")
                try check(try EditorEncoding.decode(expected, using: codec).0 == text, "Exact decode: \(codec)")
            }
        }
        test("Unrepresentable encoding rejected before state or disk mutation") {
            let url = try file("lossless.txt", Data("🙂".utf8)), document = try EditorDocument.open(url)
            for codec in [EditorEncoding.ascii, .windows1252] { try rejects { try document.setEncoding(codec) } }
            try check(document.encoding == .utf8 && !document.isModified && !document.undoManager.canUndo, "Failed Set Encoding remains atomic")
            try check(try Data(contentsOf: url) == Data("🙂".utf8), "Disk unchanged")
        }
        test("Codec-only changes dirty, undo, redo without text revision") {
            let document = EditorDocument(text: "é"), revision = document.revision
            try document.setEncoding(.windows1252)
            try check(document.isModified && document.revision == revision, "Dirty codec without revision")
            document.undoManager.undo()
            try check(document.encoding == .utf8 && !document.isModified && document.revision == revision, "Codec undo")
            document.undoManager.redo()
            try check(document.encoding == .windows1252 && document.isModified, "Codec redo")
            let path = directory.appendingPathComponent("encoded.txt"); try document.save(to: path)
            try check(!document.isModified && document.diskEncoding == .windows1252 && document.revision == revision, "Saved baseline")
            try check(try Data(contentsOf: path) == Data([0xe9]), "Selected save bytes")
        }
        test("Later unrepresentable edits fail save without corrupting disk") {
            let url = try file("legacy-save.txt", Data([0xe9])), document = try EditorDocument.open(url, encoding: .windows1252)
            document.setTextUndoably("🙂", actionName: "Unicode edit")
            try rejects { try document.save() }
            try check(try Data(contentsOf: url) == Data([0xe9]), "Rejected save leaves baseline bytes")
            try check(document.isModified && document.encoding == .windows1252, "Pending Unicode edits retained")
        }
        test("Reopen guards text and codec changes unless explicitly discarded") {
            let url = try file("reopen.txt", Data("original".utf8)), document = try EditorDocument.open(url)
            try document.setEncoding(.utf8BOM)
            try rejects { try document.reopen(using: .utf8) }
            try check(document.encoding == .utf8BOM, "Codec protected")
            document.setTextUndoably("changed", actionName: "Edit")
            try rejects { try document.reopen() }
            try document.reopen(using: .utf8, discardChanges: true)
            try check(document.storage.string == "original" && document.encoding == .utf8 && !document.isModified && !document.undoManager.canUndo, "Discard reopens new baseline")
        }
        test("Failed reopen retains text codec digest and undo state") {
            let url = try file("failed-reopen.txt", Data("old".utf8)), document = try EditorDocument.open(url)
            document.setTextUndoably("pending", actionName: "Edit")
            let digest = document.diskDigestHex, revision = document.revision
            try Data([0xff]).write(to: url)
            try rejects { try document.reopen(using: .utf8, discardChanges: true) }
            try check(document.storage.string == "pending" && document.encoding == .utf8 && document.diskDigestHex == digest && document.revision == revision && document.undoManager.canUndo, "No partial commit")
        }
        test("Successful reopen adopts external bytes and retains display settings") {
            let url = try file("external.txt", Data("old".utf8)), document = try EditorDocument.open(url)
            var config = spaces(6); config.syntax = "Packages/Python/Python.sublime-syntax"; try document.updateSettings(config)
            try Data([0xe9]).write(to: url); try document.reopen(using: .windows1252)
            try check(document.storage.string == "é" && document.settings.tabSize == 6 && document.settings.syntax == config.syntax && !document.isModified, "Fresh bytes + owned settings")
            try document.save(); try check(try Data(contentsOf: url) == Data([0xe9]), "Fresh disk baseline")
        }
        test("Display metadata persists without dirty text revision or undo") {
            let document = EditorDocument(text: "text"), revision = document.revision
            var config = spaces(128); config.syntax = "Packages/Custom/Custom.sublime-syntax"
            try document.updateSettings(config)
            try check(document.settings == config && !document.isModified && document.revision == revision && !document.undoManager.canUndo, "Metadata only")
            config.tabSize = Int.max; try document.updateSettings(config)
            try check(document.settings.tabSize == Int.max, "Positive Int setting accepted")
            config.tabSize = 0; try rejects { try document.updateSettings(config) }
            try check(document.settings.tabSize == Int.max, "Invalid metadata atomic")
        }
        test("Space Tab uses visual column and next tab stop") {
            let result = TextOperations.insertTab(in: " \tx", selections: caret(2), settings: spaces())
            try check(result.error == nil && result.text == " \t    x" && result.selections == caret(6), "Expanded next stop")
            var config = spaces(); config.useTabStops = false
            try check(TextOperations.insertTab(in: "ax", selections: caret(1), settings: config).text == "a    x", "Fixed tab width when tabstops disabled")
        }
        test("Positive large width preserved and expansion capacity fails atomically") {
            let small = TextOperations.insertTab(in: "", selections: caret(0), settings: spaces(128))
            try check(small.error == nil && small.text.count == 128, "Width above preset 8")
            let huge = TextOperations.insertTab(in: "x", selections: caret(0), settings: spaces(Int.max))
            try check(huge.error != nil && huge.text == "x" && huge.selections == caret(0), "Bounded operation without changing setting")
            try check(TextOperations.convertIndentation(in: "\t", selections: caret(1), tabSize: Int.max, toSpaces: true).error != nil, "Column overflow represented as error")
        }
        test("Shift Tab defaults honor indentation context and explicit unindent setting") {
            let config = spaces()
            try check(TextOperations.insertTab(in: "    x", selections: caret(4), settings: config, backtab: true).text == "x", "Indent context outdents")
            try check(TextOperations.insertTab(in: "abcd", selections: caret(2), settings: config, backtab: true).text == "ab  cd", "Default inline backtab inserts to stop")
            var forced = config; forced.shiftTabUnindent = true
            try check(TextOperations.insertTab(in: "    abcd", selections: caret(6), settings: forced, backtab: true).text == "abcd", "Explicit always outdent")
        }
        test("Multiline indent and outdent preserve nonselected next line") {
            let selected = [NSRange(location: 0, length: 4)]
            let indent = TextOperations.indentLines(in: "a\nb\nc", selections: selected, settings: spaces(2))
            try check(indent.text == "  a\n  b\nc" && indent.error == nil, "Exclusive selected-line end")
            let outdent = TextOperations.indentLines(in: indent.text, selections: indent.selections, settings: spaces(2), outdent: true)
            try check(outdent.text == "a\nb\nc", "Line indentation round-trip")
        }
        test("Newline honors line-ending auto-indent and simple smart indent") {
            var config = spaces(2); config.lineEnding = .crlf
            let result = TextOperations.insertNewline(in: "  if {", selections: caret(6), settings: config)
            try check(result.text == "  if {\r\n    " && result.error == nil, "Brace smart indent")
            config.smartIndent = false
            try check(TextOperations.insertNewline(in: "  if {", selections: caret(6), settings: config).text == "  if {\r\n  ", "Smart switch")
            config.autoIndent = false
            try check(TextOperations.insertNewline(in: "  if {", selections: caret(6), settings: config).text == "  if {\r\n", "Auto-indent switch")
        }
        test("Backspace and Delete obey indentation tab stops") {
            try check(TextOperations.deleteBackward(in: "      x", selections: caret(6), settings: spaces()).text == "    x", "Backspace preceding stop")
            try check(TextOperations.deleteForward(in: "      x", selections: caret(1), settings: spaces()).text == "   x", "Delete next stop")
            var config = spaces(); config.useTabStops = false
            try check(TextOperations.deleteBackward(in: "    x", selections: caret(4), settings: config).text == "   x", "Single-space backspace")
        }
        test("Delete preserves Unicode pair and CRLF indivisibility") {
            try check(TextOperations.deleteBackward(in: "🙂x", selections: caret(2), settings: spaces()).text == "x", "Backward surrogate pair")
            try check(TextOperations.deleteForward(in: "🙂x", selections: caret(0), settings: spaces()).text == "x", "Forward surrogate pair")
            try check(TextOperations.deleteBackward(in: "a\r\nb", selections: caret(3), settings: spaces()).text == "ab", "Backward CRLF")
            try check(TextOperations.deleteForward(in: "a\r\nb", selections: caret(1), settings: spaces()).text == "ab", "Forward CRLF")
            try check(TextOperations.deleteBackward(in: "🙂", selections: caret(1), settings: spaces()).error != nil, "Invalid surrogate caret rejected")
        }
        test("Multiple caret Tab edits are simultaneous") {
            let result = TextOperations.insertTab(in: "a\nb", selections: [NSRange(location: 1, length: 0), NSRange(location: 3, length: 0)], settings: spaces(2))
            try check(result.text == "a \nb " && result.selections == [NSRange(location: 2, length: 0), NSRange(location: 5, length: 0)], "Multi-caret coordinates")
        }
        test("Expand all tabs and unexpand leading-only with visual selections") {
            let expanded = TextOperations.convertIndentation(in: "\tx\ty\r\n \tz", selections: [NSRange(location: 3, length: 0), NSRange(location: 9, length: 0)], tabSize: 4, toSpaces: true)
            try check(expanded.error == nil && expanded.text == "    x   y\r\n    z", "Whole-buffer expandtabs")
            try check(expanded.selections == [NSRange(location: 8, length: 0), NSRange(location: 16, length: 0)], "Row and visual column mapping")
            let compact = TextOperations.convertIndentation(in: "    x   y\n    z", selections: caret(4), tabSize: 4, toSpaces: false)
            try check(compact.error == nil && compact.text == "\tx   y\n\tz" && compact.selections == caret(1), "Leading-only unexpand and visual caret")
        }
        test("Line column scalar and tab-expanded contract") {
            let position = TextOperations.position(in: "🙂\t甲\r\nx", utf16Offset: 4, tabSize: 4)
            try check(position?.line == 1 && position?.column == 6, "Scalar plus tab column")
            let second = TextOperations.position(in: "🙂\t甲\r\nx", utf16Offset: 7, tabSize: 4)
            try check(second?.line == 2 && second?.column == 2, "CRLF one row")
            try check(TextOperations.position(in: "🙂", utf16Offset: 1, tabSize: 4) == nil, "Invalid UTF16 point remains unknown")
        }
        test("Logical line starts share CRLF LF CR and trailing empty-line semantics") {
            try check(TextOperations.lineStarts(in: "") == [0], "Empty document has one logical line")
            try check(TextOperations.lineStarts(in: "🙂\r\n甲\r\n") == [0, 4, 7], "CRLF one line and UTF16 offsets")
            try check(TextOperations.lineStarts(in: "a\nb\r\nc\rd") == [0, 2, 5, 7], "Mixed endings")
            try check(TextOperations.lineStarts(in: "\r\n\r\n") == [0, 2, 4], "Adjacent empty CRLF lines")
            try check(TextOperations.lineStarts(in: "a\n") == [0, 2] && TextOperations.lineStarts(in: "a\r") == [0, 2], "LF CR terminal empty line")
        }
        test("Selected line starts exclude next-line endpoint and preserve empty EOF caret") {
            let text = "🙂\r\n甲\r\n" as NSString
            try check(TextOperations.lineStarts(text, [NSRange(location: 0, length: 4)]) == [0], "Exclusive endpoint after CRLF")
            try check(TextOperations.lineStarts(text, [NSRange(location: 0, length: 7)]) == [0, 4], "Terminal newline does not select empty EOF line")
            try check(TextOperations.lineStarts(text, [NSRange(location: 7, length: 0)]) == [7], "Empty EOF caret selects final line")
            try check(TextOperations.lineStarts(text, [NSRange(location: 4, length: 0), NSRange(location: 0, length: 4)]) == [0, 4], "Multi-selection deduplicates line starts")
        }
        test("Line-ending conversion owns text policy selection and undo") {
            let document = EditorDocument(text: "a\r\nb\nc\r")
            let result = document.convertLineEndings(to: .lf, selections: [NSRange(location: 3, length: 1)])
            try check(result.error == nil && document.storage.string == "a\nb\nc\n" && result.selections == [NSRange(location: 2, length: 1)] && document.settings.lineEnding == .lf, "Complete normalization with selection")
            document.undoManager.undo()
            try check(document.storage.string == "a\r\nb\nc\r" && document.settings.lineEnding == .crlf && !document.isModified, "Text and policy undo")
            document.undoManager.redo(); try check(document.storage.string == result.text && document.settings.lineEnding == .lf, "Redo normalized state")
        }
        test("Empty line-ending policy affects Enter without dirty bytes") {
            let document = EditorDocument(), revision = document.revision
            _ = document.convertLineEndings(to: .cr, selections: caret(0))
            try check(!document.isModified && document.revision == revision && document.lineEnding == "\r", "Policy only")
            try check(TextOperations.insertNewline(in: "", selections: caret(0), settings: document.settings).text == "\r", "Future newline policy")
            document.undoManager.undo(); try check(document.lineEnding == "\n" && !document.isModified, "Policy undo")
        }
        test("Detection defaults applied before text heuristic and explicit guess is independent") {
            var config = spaces(7); config.detectIndentation = true
            let document = EditorDocument(text: "  x\n    y", settings: config)
            try check(document.settings.tabSize == 2 && document.settings.translateTabsToSpaces, "Detection owns parsed settings")
            config.detectIndentation = false; try document.updateSettings(config)
            try document.detectIndentation(); try check(document.settings.tabSize == 2 && !document.settings.detectIndentation, "Explicit guess without toggling flag")
        }
        test("Syntax owner preserves requested identity and filename inference") {
            let url = try file("sample.py", Data("x".utf8)), document = try EditorDocument.open(url)
            try check(document.syntaxIdentifier == "py" && document.syntaxIsSourceCode, "Filename inference")
            var config = spaces(); config.syntax = "Packages/Custom/Alien.sublime-syntax"; try document.updateSettings(config)
            try check(document.settings.syntax == config.syntax && document.syntaxIdentifier == "unknown" && document.syntaxDisplayName == config.syntax && !document.syntaxIsSourceCode, "Unknown explicitly retained")
            config.syntax = "Packages/Python/Python.sublime-syntax"; try document.updateSettings(config)
            try check(document.syntaxIdentifier == "py" && document.syntaxDisplayName == "Python", "Known source path")
        }
        test("Settings backward-compatible decode and positive-width validation") {
            let defaults = try JSONDecoder().decode(DocumentSettings.self, from: Data("{}".utf8))
            try check(defaults == DocumentSettings(), "Missing settings fields use original defaults")
            let huge = try JSONDecoder().decode(DocumentSettings.self, from: Data("{\"tabSize\":\(Int.max)}".utf8))
            try check(huge.tabSize == Int.max, "No preset-derived upper bound")
            try rejects { _ = try JSONDecoder().decode(DocumentSettings.self, from: Data("{\"tabSize\":0}".utf8)) }
        }
        test("Session persists legacy disk codec pending codec and exact display settings") {
            let url = try file("session-legacy.txt", Data([0xe9])), document = try EditorDocument.open(url, encoding: .windows1252)
            var config = spaces(6); config.syntax = "Packages/Python/Python.sublime-syntax"; config.lineEnding = .crlf; try document.updateSettings(config)
            try document.setEncoding(.utf8BOM); document.setTextUndoably("é🙂", actionName: "Edit")
            let captured = EditorSession.Document(document: document, ranges: caret(1))
            let restored = try JSONDecoder().decode(EditorSession.Document.self, from: JSONEncoder().encode(captured)).restore()
            try check(restored.0.fileURL == url && restored.0.diskEncoding == .windows1252 && restored.0.encoding == .utf8BOM && restored.0.settings == config && restored.0.storage.string == "é🙂" && restored.0.isModified, "Owned baseline plus dirty selected codec")
            try check(restored.1 == caret(1) && !restored.0.undoManager.canUndo, "Saved selection no stale undo")
        }
        test("Session retains codec that cannot currently encode pending text") {
            let url = try file("session-unrepresentable.txt", Data([0xe9])), document = try EditorDocument.open(url, encoding: .windows1252)
            document.setTextUndoably("🙂", actionName: "Edit")
            let restored = try EditorSession.Document(document: document, ranges: caret(2)).restore().0
            try check(restored.encoding == .windows1252 && restored.storage.string == "🙂" && restored.isModified, "Pending original intent retained")
            try rejects { try restored.save() }; try check(try Data(contentsOf: url) == Data([0xe9]), "Recovery cannot silently corrupt bytes")
        }
        test("Old version-one session document fields recover with defaults") {
            let data = Data("{\"text\":\"old\",\"selections\":[[0,0]]}".utf8)
            let captured = try JSONDecoder().decode(EditorSession.Document.self, from: data)
            let restored = try captured.restore().0
            try check(restored.storage.string == "old" && restored.encoding == .utf8 && restored.settings == DocumentSettings() && restored.isModified, "Old schema recovery")
        }
        test("Changed disk session recovers untitled while retaining settings and codec") {
            let url = try file("session-changed.txt", Data("old".utf8)), document = try EditorDocument.open(url)
            var config = spaces(3); config.lineEnding = .cr; try document.updateSettings(config); try document.setEncoding(.utf8BOM)
            document.setTextUndoably("pending", actionName: "Edit")
            let captured = EditorSession.Document(document: document, ranges: caret(1))
            try Data("external".utf8).write(to: url)
            let restored = try captured.restore().0
            try check(restored.fileURL == nil && restored.diskDigestHex == nil && restored.storage.string == "pending" && restored.settings == config && restored.encoding == .utf8BOM && restored.isModified, "Old snapshot cannot adopt external baseline")
            try check(try Data(contentsOf: url) == Data("external".utf8), "External file unchanged")
        }
        let failed = results.filter { $0["status"] as? String == "failed" }.count
        let report: [String: Any] = ["suite": "document-settings", "passed": results.count - failed, "failed": failed, "tests": results,
            "verification_scope": "Own implementation, real in-memory edits and temporary file/session byte I/O; no native Sublime runtime equivalence claim."]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
        return failed == 0 ? 0 : 1
    }
}
