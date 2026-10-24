import AppKit

enum TestFailure: Error, CustomStringConvertible {
    case assertion(String)
    var description: String { if case .assertion(let text) = self { return text }; return "Test failure" }
}

enum CoreTestRunner {
    static func run() -> Int32 {
        var results: [[String: Any]] = []
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("source-editor-tests-" + UUID().uuidString)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false) }
        catch { print(error); return 1 }
        defer { try? FileManager.default.removeItem(at: directory) }
        func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            if try !condition() { throw TestFailure.assertion(message) }
        }
        func test(_ name: String, _ body: () throws -> Void) {
            let start = Date()
            do { try body(); results.append(["name": name, "status": "passed", "seconds": Date().timeIntervalSince(start)]) }
            catch { results.append(["name": name, "status": "failed", "error": String(describing: error), "seconds": Date().timeIntervalSince(start)]) }
        }
        test("UTF-16 offsets and simultaneous Unicode edits") {
            let result = TextOperations.apply(in: "甲🙂乙\n甲🙂乙", edits: [
                TextReplacement(range: NSRange(location: 1, length: 2), text: "X"),
                TextReplacement(range: NSRange(location: 6, length: 2), text: "Y")])
            try check(result.error == nil && result.text == "甲X乙\n甲Y乙", "Unicode edit result: \(result.text), \(result.error ?? "")")
            try check(result.selections == [NSRange(location: 2, length: 0), NSRange(location: 6, length: 0)], "Cursor mapping")
        }
        test("Reject overlapping edits without partial mutation") {
            let result = TextOperations.apply(in: "abcdef", edits: [
                TextReplacement(range: NSRange(location: 1, length: 3), text: "X"),
                TextReplacement(range: NSRange(location: 2, length: 2), text: "Y")])
            try check(result.error != nil && result.text == "abcdef", "Overlapping edit admission")
        }
        test("Reject surrogate splitting and invalid ranges") {
            for range in [NSRange(location: 1, length: 1), NSRange(location: 3, length: 2), NSRange(location: Int.max, length: 1)] {
                let result = TextOperations.apply(in: "🙂a", edits: [TextReplacement(range: range, text: "X")])
                try check(result.error != nil && result.text == "🙂a", "Invalid Unicode/range admission")
            }
        }
        test("Stable lower-key sort preserves terminal newline") {
            let result = TextOperations.sortLines(in: "b\nA\na\n", selections: [NSRange(location: 0, length: 0)])
            try check(result.text == "A\na\nb\n", "Sort result: \(String(reflecting: result.text))")
        }
        test("Sort retains leading and trailing blank lines") {
            let result = TextOperations.sortLines(in: "\n b\n A\n \n", selections: [NSRange(location: 0, length: 0)])
            try check(result.text == "\n A\n b\n \n", "Whitespace boundary: \(String(reflecting: result.text))")
        }
        test("Sort whole-line selected range keeps other text") {
            let result = TextOperations.sortLines(in: "z\nb\na\ny", selections: [NSRange(location: 2, length: 3)])
            try check(result.text == "z\na\nb\ny", "Selection expansion: \(String(reflecting: result.text))")
        }
        test("Sort reverse and exact duplicate handling") {
            let result = TextOperations.sortLines(in: "b\nA\na\nA", selections: [], reverse: true, removeDuplicates: true)
            try check(result.text == "b\nA\na", "Reverse/unique: \(String(reflecting: result.text))")
            let distinct = TextOperations.sortLines(in: "e\u{301}\né", selections: [], removeDuplicates: true)
            try check(distinct.text.components(separatedBy: "\n").count == 2, "Do not fold canonical equivalents during exact unique")
        }
        test("CRLF survives sort") {
            let result = TextOperations.sortLines(in: "b\r\nA\r\na\r\n", selections: [])
            try check(result.text == "A\r\na\r\nb\r\n", "CRLF sort")
        }
        test("Case conversion and word-at-caret") {
            let result = TextOperations.transform(in: "one TWO", selections: [NSRange(location: 1, length: 0)], upper: true)
            try check(result.text == "ONE TWO", "Word upper-case")
        }
        test("Undo and redo restore exact document and dirty state") {
            let document = EditorDocument(text: "原文🙂")
            document.replace([TextReplacement(range: NSRange(location: 0, length: 2), text: "修改")])
            try check(document.isModified && document.undoManager.canUndo, "Modified and undo registered")
            document.undoManager.undo()
            try check(document.storage.string == "原文🙂" && !document.isModified, "Undo original state")
            document.undoManager.redo()
            try check(document.storage.string == "修改🙂" && document.isModified, "Redo modified state")
        }
        test("UTF-8 and mixed line endings round-trip exactly") {
            let path = directory.appendingPathComponent("mixed.txt")
            let bytes = Data("甲🙂\r\n乙\n丙\r".utf8)
            try bytes.write(to: path)
            let document = try EditorDocument.open(path)
            try document.save()
            try check(try Data(contentsOf: path) == bytes, "Unchanged byte round-trip")
        }
        test("UTF-8 BOM and UTF-16 endian variants remain intact") {
            let text = "中文🙂\r\n"
            let variants = [Data([0xef, 0xbb, 0xbf]) + Data(text.utf8),
                            Data([0xff, 0xfe]) + text.data(using: .utf16LittleEndian)!,
                            Data([0xfe, 0xff]) + text.data(using: .utf16BigEndian)!]
            for (index, bytes) in variants.enumerated() {
                let path = directory.appendingPathComponent("bom-\(index).txt")
                try bytes.write(to: path)
                let document = try EditorDocument.open(path)
                try check(document.storage.string == text, "BOM decode")
                try document.save()
                try check(try Data(contentsOf: path) == bytes, "BOM encode round-trip")
            }
        }
        test("Invalid UTF-8 is rejected rather than replaced") {
            let path = directory.appendingPathComponent("invalid.txt")
            try Data([0xc3, 0x28]).write(to: path)
            do { _ = try EditorDocument.open(path); throw TestFailure.assertion("Invalid encoding was accepted") }
            catch EditorFailure.unsupportedEncoding { }
        }
        test("External file changes block save and remain untouched") {
            let path = directory.appendingPathComponent("external.txt")
            try Data("first".utf8).write(to: path)
            let document = try EditorDocument.open(path)
            document.storage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "mine")
            let external = Data("other editor".utf8)
            try external.write(to: path)
            do { try document.save(); throw TestFailure.assertion("Conflict overwritten") }
            catch EditorFailure.changedOnDisk { }
            try check(try Data(contentsOf: path) == external, "External content preserved")
        }
        test("New saves protect existing destinations and preserve permissions") {
            let path = directory.appendingPathComponent("permission.txt")
            try Data("original".utf8).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path.path)
            let document = EditorDocument(text: "new")
            do { try document.save(to: path); throw TestFailure.assertion("Existing destination silently replaced") }
            catch EditorFailure.destinationExists { }
            try document.save(to: path, allowOverwrite: true)
            let mode = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as! NSNumber
            try check(mode.intValue == 0o640 && !document.isModified, "Permissions and saved checkpoint")
        }
        test("Saving through a symlink preserves the link") {
            let target = directory.appendingPathComponent("target.txt"), link = directory.appendingPathComponent("link.txt")
            try Data("target".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let document = try EditorDocument.open(link)
            document.storage.replaceCharacters(in: NSRange(location: 0, length: 6), with: "updated")
            try document.save()
            _ = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
            try check(try Data(contentsOf: target) == Data("updated".utf8), "Resolved target saved")
        }
        test("Literal and regex search, captures, and invalid regex") {
            try check(try SearchEngine.find(in: "A.a Axa", query: "A.a", caseSensitive: true).count == 1, "Literal matching")
            try check(try SearchEngine.find(in: "A.a Axa", query: "a.a", regex: true).count == 2, "Regex matching")
            let replaced = try SearchEngine.replacing(in: "item12 item34", query: "item([0-9]+)", replacement: "n$1", regex: true)
            try check(replaced.text == "n12 n34", "Replacement captures")
            do { _ = try SearchEngine.find(in: "x", query: "[", regex: true); throw TestFailure.assertion("Invalid regex accepted") }
            catch let error as NSError where error.domain == NSCocoaErrorDomain { }
        }
        test("Independent layout managers share one document storage") {
            let document = EditorDocument(text: "same")
            let left = NSLayoutManager(), right = NSLayoutManager()
            document.storage.addLayoutManager(left); document.storage.addLayoutManager(right)
            document.storage.replaceCharacters(in: NSRange(location: 0, length: 4), with: "both")
            try check(left.textStorage === right.textStorage && left.textStorage?.string == "both", "Split source ownership")
        }
#if !CORE_ONLY_TEST
        test("Session preserves dirty text and protects externally changed files") {
            let path = directory.appendingPathComponent("session-document.txt")
            try Data("disk".utf8).write(to: path)
            let document = try EditorDocument.open(path)
            document.setTextUndoably("unsaved😀", actionName: "Edit")
            let session = EditorSession(projectPath: directory.path, selectedIndex: 0, split: true,
                                        documents: [EditorSession.Document(document: document, ranges: [NSRange(location: 7, length: 2)])])
            let file = directory.appendingPathComponent("session.json")
            try session.save(file)
            let loaded = try EditorSession.load(file)
            let (same, ranges) = loaded.documents[0].restore()
            try check(same.fileURL == path && same.isModified && same.storage.string == "unsaved😀", "Dirty session roundtrip")
            try check(ranges == [NSRange(location: 7, length: 2)], "Unicode selection restored")
            try Data("external".utf8).write(to: path)
            let (recovered, _) = loaded.documents[0].restore()
            try check(recovered.fileURL == nil && recovered.isModified && recovered.storage.string == "unsaved😀", "Changed original recovers untitled")
            try check(try Data(contentsOf: path) == Data("external".utf8), "Recovery does not change disk")
        }
        test("Project preserves unknown JSON fields and relative folder identity") {
            let source = directory.appendingPathComponent("project.json")
            let object: [String: Any] = ["folders": [["path": ".", "exclude": ["cache"]]], "custom_field": ["keep": true]]
            try JSONSerialization.data(withJSONObject: object).write(to: source)
            let project = try EditorProject.load(source)
            let targetDir = directory.appendingPathComponent("relocated")
            try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: false)
            let target = targetDir.appendingPathComponent("project.json")
            try project.save(target)
            let restored = try EditorProject.load(target)
            try check(restored.folderURL == directory.standardizedFileURL, "Relative folder identity after Save As")
            let custom = restored.values["custom_field"] as? [String: Bool]
            let folders = restored.values["folders"] as? [[String: Any]]
            try check(custom?["keep"] == true && folders?[0]["exclude"] as? [String] == ["cache"], "Unknown fields preserved")
        }
#endif
        let failures = results.filter { $0["status"] as? String == "failed" }
        let report: [String: Any] = ["suite": "source-editor-core", "target": "independent reconstruction; not a Sublime runtime test",
                                     "passed": results.count - failures.count, "failed": failures.count, "results": results]
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        return failures.isEmpty ? 0 : 1
    }
}
