import AppKit
import CryptoKit

enum EditorFailure: LocalizedError {
    case unsupportedEncoding, missingDestination, changedOnDisk, destinationExists, invalidEdit(String)
    var errorDescription: String? {
        switch self {
        case .unsupportedEncoding: return "文件不符合指定编码；自动检测支持有效 UTF-8 和带 BOM 的 UTF-16。"
        case .missingDestination: return "请先选择保存位置。"
        case .changedOnDisk: return "文件已被其他程序修改。请重新打开，或另存为后再处理差异。"
        case .destinationExists: return "目标文件已存在，请确认覆盖或选择新位置。"
        case .invalidEdit(let reason): return reason
        }
    }
}

final class EditorDocument: NSObject, NSTextStorageDelegate {
    let storage: NSTextStorage
    let undoManager = UndoManager()
    private(set) var fileURL: URL?
    private(set) var imageAsset: EditorImageAsset?
    var isTextDocument: Bool { imageAsset == nil }
    private(set) var revision: UInt64 = 0
    private(set) var encoding = EditorEncoding.utf8
    private(set) var settings: DocumentSettings
    private var diskDigest: Data?
    var diskDigestHex: String? { diskDigest?.map { String(format: "%02x", $0) }.joined() }
    private var savedText: String
    private var cachedTextModified: Bool? = false
    private var cachedLineIndex: DocumentLineIndex?
    private var cachedHighlights: (syntax: String, value: SyntaxHighlights)?
    private var presentation: (font: NSFont, paragraph: NSParagraphStyle, foreground: NSColor)?
    private(set) var diskEncoding = EditorEncoding.utf8
    var displayName: String { fileURL?.lastPathComponent ?? "Untitled" }
    var isModified: Bool {
        guard isTextDocument else { return false }
        if encoding != diskEncoding { return true }
        if let cachedTextModified { return cachedTextModified }
        let source = storage.string as NSString
        let changed = source.length != (savedText as NSString).length || source.compare(savedText, options: .literal) != .orderedSame
        cachedTextModified = changed
        return changed
    }
    var lineIndex: DocumentLineIndex {
        if let cachedLineIndex { return cachedLineIndex }
        let index = DocumentLineIndex(storage.string as NSString)
        cachedLineIndex = index
        return index
    }
    func position(at offset: Int) -> (line: Int, column: Int)? {
        lineIndex.position(in: storage.string as NSString, utf16Offset: offset, tabSize: settings.tabSize)
    }
    var syntaxHighlights: SyntaxHighlights {
        let syntax = syntaxIdentifier
        if let cachedHighlights, cachedHighlights.syntax == syntax { return cachedHighlights.value }
        let source = storage.length <= 2_000_000 && SyntaxHighlights.supported.contains(syntax) ? storage.string : ""
        let value = SyntaxHighlights(text: source, syntax: syntax)
        cachedHighlights = (syntax, value)
        return value
    }
    var lineEnding: String { settings.lineEnding.text }
    var encodingDescription: String { encoding.displayName }
    var resolvedSyntax: EditorSyntax? {
        if let supplied = settings.syntax { return EditorSyntax.resolve(supplied) }
        return fileURL.flatMap { EditorSyntax.resolve($0.pathExtension) } ?? .plainText
    }
    var syntaxIdentifier: String { resolvedSyntax?.identifier ?? "unknown" }
    var syntaxDisplayName: String { resolvedSyntax?.displayName ?? settings.syntax ?? "Unknown" }
    var syntaxIsSourceCode: Bool { resolvedSyntax?.isSourceCode ?? false }

    init(text: String = "", settings: DocumentSettings = DocumentSettings()) {
        storage = NSTextStorage(string: text)
        savedText = text
        self.settings = settings.detectIndentation ? TextOperations.detectedIndentation(in: text, defaults: settings) : settings
        if text.contains("\n") || text.contains("\r") { self.settings.lineEnding = LineEnding.detect(in: text) }
        super.init()
        storage.delegate = self
    }

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        // Invalidate at the text owner, including native edits, undo and recovery.
        // Font/paragraph updates do not change these text facts.
        guard editedMask.contains(.editedCharacters) else { return }
        cachedTextModified = nil
        cachedLineIndex = nil
        cachedHighlights = nil
        presentation = nil
    }

    // Storage attributes belong to the document shared by every split pane.
    // Reattaching a view must not rewrite a whole unchanged document. Character
    // edits invalidate this presentation because native typing/undo can supply
    // different attributes; text facts and dirty state are independent of it.
    func applyPresentation(font: NSFont, paragraph: NSParagraphStyle, foreground: NSColor) {
        if let presentation, presentation.font == font,
           presentation.paragraph == paragraph,
           presentation.foreground == foreground { return }
        storage.beginEditing()
        storage.addAttributes([.font: font, .paragraphStyle: paragraph, .foregroundColor: foreground],
                              range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
        presentation = (font, paragraph.copy() as! NSParagraphStyle, foreground)
    }

    static func open(_ url: URL, encoding: EditorEncoding? = nil, settings: DocumentSettings = DocumentSettings(), asImage: Bool = false) throws -> EditorDocument {
        try settings.validate()
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        if asImage || EditorImageAsset.supports(resolved) {
            let asset = try EditorImageAsset.load(resolved)
            let document = EditorDocument(settings: settings)
            document.fileURL = resolved; document.imageAsset = asset
            return document
        }
        let data = try Data(contentsOf: resolved)
        let (text, codec) = try EditorEncoding.decode(data, using: encoding)
        let document = EditorDocument(text: text, settings: settings)
        document.fileURL = resolved
        document.encoding = codec
        document.diskEncoding = codec
        document.diskDigest = Data(SHA256.hash(data: data))
        return document
    }

    func markChanged() {
        revision &+= 1
        NotificationCenter.default.post(name: .editorDocumentChanged, object: self)
    }

    func checkpoint() {
        savedText = storage.string
        cachedTextModified = false
        diskEncoding = encoding
        notifyChanged()
    }

    func relocate(to url: URL) {
        fileURL = url.standardizedFileURL.resolvingSymlinksInPath()
        if let asset = imageAsset, let fileURL {
            imageAsset = EditorImageAsset(url: fileURL, width: asset.width, height: asset.height,
                bytes: asset.bytes, modified: asset.modified, frames: asset.frames)
        }
        markChanged()
    }
    func detachAfterTrash() {
        fileURL = nil; diskDigest = nil; savedText = ""; cachedTextModified = nil
        markChanged()
    }
    func acceptExternalText(_ text: String, encoding: EditorEncoding, digest: Data) {
        guard isTextDocument, !isModified else { return }
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        savedText = text; self.encoding = encoding; diskEncoding = encoding; diskDigest = digest
        settings.lineEnding = LineEnding.detect(in: text); cachedTextModified = false
        undoManager.removeAllActions(); markChanged()
    }

    private func notifyChanged() { NotificationCenter.default.post(name: .editorDocumentChanged, object: self) }

    func updateSettings(_ value: DocumentSettings) throws {
        try requireTextDocument()
        try value.validate()
        guard settings != value else { return }
        settings = value
        notifyChanged()
    }

    func detectIndentation() throws {
        try updateSettings(TextOperations.detectedIndentation(in: storage.string, defaults: settings))
    }

    func setEncoding(_ value: EditorEncoding) throws {
        try requireTextDocument()
        _ = try value.encode(storage.string)
        changeUndoably(text: storage.string, encoding: value, ending: settings.lineEnding, actionName: "Set Encoding")
    }

    func reopen(using value: EditorEncoding? = nil, discardChanges: Bool = false) throws {
        guard let url = fileURL else { throw EditorFailure.missingDestination }
        if imageAsset != nil {
            imageAsset = try EditorImageAsset.load(url)
            markChanged()
            return
        }
        guard discardChanges || !isModified else { throw EditorFailure.invalidEdit("文档有未保存的文本或编码更改；重新打开前请保存，或明确丢弃更改。") }
        let data = try Data(contentsOf: url)
        let (text, decodedEncoding) = try EditorEncoding.decode(data, using: value)
        // Commit only after the complete read and strict decode have succeeded.
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        savedText = text; encoding = decodedEncoding; diskEncoding = decodedEncoding
        cachedTextModified = false
        diskDigest = Data(SHA256.hash(data: data))
        settings.lineEnding = LineEnding.detect(in: text)
        undoManager.removeAllActions()
        markChanged()
    }

    @discardableResult
    func convertLineEndings(to value: LineEnding, selections: [NSRange]) -> TextEditResult {
        guard isTextDocument else { return TextEditResult(text: storage.string, selections: selections, error: "Image previews are read-only.") }
        let result = TextOperations.convertingLineEndings(in: storage.string, selections: selections, to: value)
        guard result.error == nil else { return result }
        changeUndoably(text: result.text, encoding: encoding, ending: value, actionName: "Convert Line Endings")
        return result
    }

    // Recovery preserves the selected codec even when later edits are no longer
    // representable in it. Save remains the boundary that must reject data loss.
    func restoreSessionState(text: String, encoding: EditorEncoding?, settings: DocumentSettings?) {
        guard isTextDocument else { return }
        let changed = !storage.string.utf16.elementsEqual(text.utf16)
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        if let encoding { self.encoding = encoding }
        if let settings { self.settings = settings }
        undoManager.removeAllActions()
        if changed { markChanged() } else { notifyChanged() }
    }

    func save(to url: URL? = nil, allowOverwrite: Bool = false) throws {
        try requireTextDocument()
        guard let requested = url ?? fileURL else { throw EditorFailure.missingDestination }
        let destination = requested.standardizedFileURL.resolvingSymlinksInPath()
        let exists = FileManager.default.fileExists(atPath: destination.path)
        var permissions: Any?
        if exists {
            if destination == fileURL, let expected = diskDigest {
                let current = try Data(contentsOf: destination)
                guard Data(SHA256.hash(data: current)) == expected else { throw EditorFailure.changedOnDisk }
            } else if !allowOverwrite {
                throw EditorFailure.destinationExists
            }
            permissions = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions]
        } else if destination == fileURL && diskDigest != nil {
            throw EditorFailure.changedOnDisk
        }
        let data = try encoding.encode(storage.string)
        try data.write(to: destination, options: .atomic)
        if let mode = permissions {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: destination.path)
        }
        fileURL = destination
        diskDigest = Data(SHA256.hash(data: data))
        checkpoint()
    }

    @discardableResult
    func replace(_ replacements: [TextReplacement], actionName: String = "Edit") -> TextEditResult {
        guard isTextDocument else { return TextEditResult(text: storage.string, selections: [], error: "Image previews are read-only.") }
        let previous = storage.string
        let result = TextOperations.apply(in: previous, edits: replacements)
        guard result.error == nil else { return result }
        setTextUndoably(result.text, actionName: actionName)
        return result
    }

    func setTextUndoably(_ text: String, actionName: String) {
        changeUndoably(text: text, encoding: encoding, ending: settings.lineEnding, actionName: actionName)
    }

    private func changeUndoably(text: String, encoding: EditorEncoding, ending: LineEnding, actionName: String) {
        guard isTextDocument else { return }
        let previous = storage.string, previousEncoding = self.encoding, previousEnding = settings.lineEnding
        let textChanged = !previous.utf16.elementsEqual(text.utf16)
        guard textChanged || previousEncoding != encoding || previousEnding != ending else { return }
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { document in
            document.changeUndoably(text: previous, encoding: previousEncoding, ending: previousEnding, actionName: actionName)
        }
        if textChanged { storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text) }
        self.encoding = encoding; settings.lineEnding = ending
        undoManager.setActionName(actionName)
        undoManager.endUndoGrouping()
        if textChanged { markChanged() } else { notifyChanged() }
    }

    private func requireTextDocument() throws {
        guard isTextDocument else { throw EditorFailure.invalidEdit("Image previews are read-only. Use an image editor to change the original.") }
    }
}

extension Notification.Name {
    static let editorDocumentChanged = Notification.Name("SourceEditor.documentChanged")
}

struct TextReplacement {
    var range: NSRange
    var text: String
}

struct TextEditResult {
    var text: String
    var selections: [NSRange]
    var error: String? = nil
}

enum TextOperations {
    static func isBoundary(_ position: Int, in units: [UInt16]) -> Bool {
        if position < 0 || position > units.count { return false }
        if position == 0 || position == units.count { return true }
        return !(0xd800...0xdbff).contains(units[position - 1]) || !(0xdc00...0xdfff).contains(units[position])
    }

    static func apply(in text: String, edits: [TextReplacement]) -> TextEditResult {
        let units = Array(text.utf16)
        let ordered = edits.sorted { $0.range.location < $1.range.location }
        var end = -1
        for edit in ordered {
            let range = edit.range
            guard range.location >= 0, range.length >= 0, range.location <= units.count,
                  range.length <= units.count - range.location,
                  isBoundary(range.location, in: units), isBoundary(NSMaxRange(range), in: units) else {
                return TextEditResult(text: text, selections: [], error: "编辑范围超出文本或切断 Unicode 字符。")
            }
            guard range.location >= end else {
                return TextEditResult(text: text, selections: [], error: "编辑范围相互重叠。")
            }
            end = NSMaxRange(range)
        }
        let mutable = NSMutableString(string: text)
        for edit in ordered.reversed() { mutable.replaceCharacters(in: edit.range, with: edit.text) }
        var delta = 0
        let cursors = ordered.map { edit -> NSRange in
            let length = (edit.text as NSString).length
            let cursor = NSRange(location: edit.range.location + delta + length, length: 0)
            delta += length - edit.range.length
            return cursor
        }
        return TextEditResult(text: mutable as String, selections: cursors)
    }

    private static func lineRegion(in string: NSString, selection: NSRange) -> NSRange? {
        let length = string.length
        guard selection.location >= 0, selection.location <= length,
              selection.length >= 0, selection.length <= length - selection.location else { return nil }
        var start = 0, end = 0, contentsEnd = 0
        string.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: selection)
        var a = start, b = contentsEnd
        let whitespace = CharacterSet.whitespacesAndNewlines
        func blank(_ at: Int) -> Bool {
            guard let scalar = UnicodeScalar(string.character(at: at)) else { return false }
            return whitespace.contains(scalar)
        }
        while a < b && blank(a) { a += 1 }
        while b > a && blank(b - 1) { b -= 1 }
        guard b > a else { return nil }
        string.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: a, length: b - a))
        return NSRange(location: start, length: contentsEnd - start)
    }

    static func sortLines(in text: String, selections: [NSRange], caseSensitive: Bool = false,
                          reverse: Bool = false, removeDuplicates: Bool = false) -> TextEditResult {
        let string = text as NSString
        var regions = selections.filter { $0.length > 0 }.compactMap { lineRegion(in: string, selection: $0) }
        if regions.isEmpty, let whole = lineRegion(in: string, selection: NSRange(location: 0, length: string.length)) {
            regions = [whole]
        }
        regions.sort { $0.location < $1.location }
        var merged: [NSRange] = []
        for range in regions {
            if let previous = merged.last, range.location <= NSMaxRange(previous) {
                merged[merged.count - 1] = NSUnionRange(previous, range)
            } else { merged.append(range) }
        }
        let replacements = merged.map { range -> TextReplacement in
            let selected = string.substring(with: range)
            let separator = selected.contains("\r\n") ? "\r\n" : selected.contains("\r") ? "\r" : "\n"
            let lines = selected.components(separatedBy: separator)
            var sorted = lines.enumerated().map { index, line in
                (index: index, text: line, key: Array((caseSensitive ? line : line.lowercased()).unicodeScalars.map(\.value)))
            }.sorted { a, b in a.key == b.key ? a.index < b.index : a.key.lexicographicallyPrecedes(b.key) }.map(\.text)
            if reverse { sorted.reverse() }
            if removeDuplicates {
                var seen = Set<[UInt32]>()
                sorted = sorted.filter { seen.insert(Array($0.unicodeScalars.map(\.value))).inserted }
            }
            return TextReplacement(range: range, text: sorted.joined(separator: separator))
        }
        let result = apply(in: text, edits: replacements)
        guard result.error == nil else { return result }
        var offset = 0
        let selected = replacements.map { replacement -> NSRange in
            let newLength = (replacement.text as NSString).length
            let range = NSRange(location: replacement.range.location + offset, length: newLength)
            offset += newLength - replacement.range.length
            return range
        }
        return TextEditResult(text: result.text, selections: selected.isEmpty ? selections : selected)
    }

    static func transform(in text: String, selections: [NSRange], upper: Bool) -> TextEditResult {
        let string = text as NSString
        let edits = selections.map { selection -> TextReplacement in
            var range = selection
            if range.length == 0 && range.location < string.length {
                let characters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
                func word(_ at: Int) -> Bool {
                    guard let scalar = UnicodeScalar(string.character(at: at)) else { return false }
                    return characters.contains(scalar)
                }
                var a = range.location, b = a
                while a > 0 && word(a - 1) { a -= 1 }
                while b < string.length && word(b) { b += 1 }
                range = NSRange(location: a, length: b - a)
            }
            guard range.location >= 0, range.location <= string.length, range.length >= 0,
                  range.length <= string.length - range.location else { return TextReplacement(range: range, text: "") }
            let selected = string.substring(with: range)
            return TextReplacement(range: range, text: upper ? selected.uppercased() : selected.lowercased())
        }
        return apply(in: text, edits: edits)
    }
}
