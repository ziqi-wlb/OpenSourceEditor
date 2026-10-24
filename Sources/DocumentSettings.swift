import AppKit
import CoreFoundation

enum EditorEncoding: String, Codable, CaseIterable {
    case utf8, utf8BOM, utf16LE, utf16LEBOM, utf16BE, utf16BEBOM
    case ascii, windows1252, latin1, latin2, latin9, macRoman, gb18030, big5
    case windows1251, koi8R, koi8U, cp437, cp862, cp865, shiftJIS, eucJP
    case arabicISO, windows1256, balticISO, windows1257, celticISO, macCentralEuropean, windows1250
    case cyrillicISO, cp866, estonianISO, greekISO, windows1253, hebrewISO, windows1255
    case nordicISO, romanianISO, turkishISO, windows1254, windows1258, latin3

    var displayName: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf8BOM: return "UTF-8 with BOM"
        case .utf16LE: return "UTF-16 LE"
        case .utf16LEBOM: return "UTF-16 LE with BOM"
        case .utf16BE: return "UTF-16 BE"
        case .utf16BEBOM: return "UTF-16 BE with BOM"
        case .ascii: return "ASCII"
        case .windows1252: return "Western (Windows 1252)"
        case .latin1: return "Western (ISO 8859-1)"
        case .latin2: return "Central European (ISO 8859-2)"
        case .latin9: return "Western (ISO 8859-15)"
        case .macRoman: return "Western (Mac Roman)"
        case .gb18030: return "Chinese (GB18030)"
        case .big5: return "Chinese (Big5)"
        case .windows1251: return "Cyrillic (Windows 1251)"
        case .koi8R: return "Cyrillic (KOI8-R)"
        case .koi8U: return "Cyrillic (KOI8-U)"
        case .cp437: return "DOS (CP 437)"
        case .cp862: return "Hebrew (CP 862)"
        case .cp865: return "Nordic (Windows 865)"
        case .shiftJIS: return "Japanese (Shift JIS)"
        case .eucJP: return "Japanese (EUC-JP)"
        case .arabicISO: return "Arabic (ISO 8859-6)"
        case .windows1256: return "Arabic (Windows 1256)"
        case .balticISO: return "Baltic (ISO 8859-4)"
        case .windows1257: return "Baltic (Windows 1257)"
        case .celticISO: return "Celtic (ISO 8859-14)"
        case .macCentralEuropean: return "Central European (Mac)"
        case .windows1250: return "Central European (Windows 1250)"
        case .cyrillicISO: return "Cyrillic (ISO 8859-5)"
        case .cp866: return "Cyrillic (Windows 866)"
        case .estonianISO: return "Estonian (ISO 8859-13)"
        case .greekISO: return "Greek (ISO 8859-7)"
        case .windows1253: return "Greek (Windows 1253)"
        case .hebrewISO: return "Hebrew (ISO 8859-8)"
        case .windows1255: return "Hebrew (Windows 1255)"
        case .nordicISO: return "Nordic (ISO 8859-10)"
        case .romanianISO: return "Romanian (ISO 8859-16)"
        case .turkishISO: return "Turkish (ISO 8859-9)"
        case .windows1254: return "Turkish (Windows 1254)"
        case .windows1258: return "Vietnamese (Windows 1258)"
        case .latin3: return "Western (ISO 8859-3)"
        }
    }

    private var foundationEncoding: String.Encoding {
        let cf: CFStringEncoding
        switch self {
        case .utf8, .utf8BOM: return .utf8
        case .utf16LE, .utf16LEBOM: return .utf16LittleEndian
        case .utf16BE, .utf16BEBOM: return .utf16BigEndian
        case .ascii: return .ascii
        case .windows1252: return .windowsCP1252
        case .latin1: return .isoLatin1
        case .latin2: cf = 0x0202
        case .latin9: cf = 0x020f
        case .macRoman: return .macOSRoman
        case .gb18030: cf = 0x0632
        case .big5: cf = 0x0a03
        case .windows1251: cf = 0x0502
        case .koi8R: cf = 0x0a02
        case .koi8U: cf = 0x0a08
        case .cp437: cf = 0x0400
        case .cp862: cf = 0x0417
        case .cp865: cf = 0x041a
        case .shiftJIS: cf = 0x0a01
        case .eucJP: cf = 0x0920
        case .arabicISO: cf = 0x0206
        case .windows1256: cf = 0x0506
        case .balticISO: cf = 0x0204
        case .windows1257: cf = 0x0507
        case .celticISO: cf = 0x020e
        case .macCentralEuropean: cf = 29
        case .windows1250: cf = 0x0501
        case .cyrillicISO: cf = 0x0205
        case .cp866: cf = 0x041b
        case .estonianISO: cf = 0x020d
        case .greekISO: cf = 0x0207
        case .windows1253: cf = 0x0503
        case .hebrewISO: cf = 0x0208
        case .windows1255: cf = 0x0505
        case .nordicISO: cf = 0x020a
        case .romanianISO: cf = 0x0210
        case .turkishISO: cf = 0x0209
        case .windows1254: cf = 0x0504
        case .windows1258: cf = 0x0508
        case .latin3: cf = 0x0203
        }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    private var bom: Data {
        switch self {
        case .utf8BOM: return Data([0xef, 0xbb, 0xbf])
        case .utf16LEBOM: return Data([0xff, 0xfe])
        case .utf16BEBOM: return Data([0xfe, 0xff])
        default: return Data()
        }
    }
    var hasBOM: Bool { !bom.isEmpty }
    // Shipped text-codec menu inventory; Hexadecimal is a distinct byte-view mode.
    var isShippedTextEncoding: Bool { ![.ascii, .big5, .shiftJIS, .eucJP].contains(self) }

    func encode(_ text: String) throws -> Data {
        guard let bytes = text.data(using: foundationEncoding, allowLossyConversion: false),
              let decoded = String(data: bytes, encoding: foundationEncoding), decoded.utf16.elementsEqual(text.utf16) else {
            throw EditorFailure.invalidEdit("文本含有 \(displayName) 无法无损表示的字符，未写入文件。")
        }
        return bom + bytes
    }

    static func decode(_ data: Data, using requested: EditorEncoding? = nil) throws -> (String, EditorEncoding) {
        let bytes = [UInt8](data.prefix(3))
        let selected: EditorEncoding
        if let requested { selected = requested }
        else if bytes.starts(with: [0xff, 0xfe]) { selected = .utf16LEBOM }
        else if bytes.starts(with: [0xfe, 0xff]) { selected = .utf16BEBOM }
        else if bytes.starts(with: [0xef, 0xbb, 0xbf]) { selected = .utf8BOM }
        else { selected = .utf8 }
        var payload = data
        var actual = selected
        switch selected {
        case .utf8, .utf8BOM:
            let hasBOM = bytes.starts(with: [0xef, 0xbb, 0xbf])
            if hasBOM { payload = Data(data.dropFirst(3)) }
            actual = hasBOM ? .utf8BOM : .utf8
        case .utf16LE, .utf16LEBOM:
            let hasBOM = bytes.starts(with: [0xff, 0xfe])
            if hasBOM { payload = Data(data.dropFirst(2)) }
            actual = hasBOM ? .utf16LEBOM : .utf16LE
            guard payload.count % 2 == 0 else { throw EditorFailure.unsupportedEncoding }
        case .utf16BE, .utf16BEBOM:
            let hasBOM = bytes.starts(with: [0xfe, 0xff])
            if hasBOM { payload = Data(data.dropFirst(2)) }
            actual = hasBOM ? .utf16BEBOM : .utf16BE
            guard payload.count % 2 == 0 else { throw EditorFailure.unsupportedEncoding }
        default: break
        }
        if [.utf16LE, .utf16LEBOM, .utf16BE, .utf16BEBOM].contains(selected) {
            let little = selected == .utf16LE || selected == .utf16LEBOM
            let raw = Array(payload)
            var index = 0
            while index < raw.count {
                let unit = little ? UInt16(raw[index]) | UInt16(raw[index + 1]) << 8 : UInt16(raw[index]) << 8 | UInt16(raw[index + 1])
                index += 2
                if (0xd800...0xdbff).contains(unit) {
                    guard index < raw.count else { throw EditorFailure.unsupportedEncoding }
                    let next = little ? UInt16(raw[index]) | UInt16(raw[index + 1]) << 8 : UInt16(raw[index]) << 8 | UInt16(raw[index + 1])
                    guard (0xdc00...0xdfff).contains(next) else { throw EditorFailure.unsupportedEncoding }
                    index += 2
                } else if (0xdc00...0xdfff).contains(unit) { throw EditorFailure.unsupportedEncoding }
            }
        }
        guard let text = String(data: payload, encoding: selected.foundationEncoding) else { throw EditorFailure.unsupportedEncoding }
        return (text, actual)
    }
}

enum LineEnding: String, Codable, CaseIterable {
    case lf, crlf, cr
    var text: String { self == .lf ? "\n" : self == .crlf ? "\r\n" : "\r" }
    var displayName: String {
        switch self {
        case .lf: return "Unix Line Endings (LF)"
        case .crlf: return "Windows Line Endings (CRLF)"
        case .cr: return "Mac OS 9 Line Endings (CR)"
        }
    }
    static func detect(in text: String) -> LineEnding {
        if text.contains("\r\n") { return .crlf }
        if text.contains("\r") { return .cr }
        return .lf
    }
}

enum EditorSyntax: String, CaseIterable {
    case plainText = "plain_text", swift, python, javascript, typescript, json, markdown, html, css, c, cpp, shell, yaml, rust, go, xml, sql
    var displayName: String {
        switch self {
        case .plainText: return "Plain Text"
        case .javascript: return "JavaScript"
        case .typescript: return "TypeScript"
        case .json: return "JSON"
        case .html: return "HTML"
        case .css: return "CSS"
        case .c: return "C"
        case .cpp: return "C++"
        case .yaml: return "YAML"
        case .xml: return "XML"
        case .sql: return "SQL"
        default: return rawValue.capitalized
        }
    }
    var identifier: String {
        switch self {
        case .plainText: return "txt"
        case .python: return "py"
        case .javascript: return "js"
        case .typescript: return "ts"
        case .markdown: return "md"
        case .shell: return "sh"
        case .yaml: return "yml"
        case .rust: return "rs"
        default: return rawValue
        }
    }
    // HTML/XML are our supported text-markup classification, not a recovered native scope verdict.
    var isSourceCode: Bool { ![.plainText, .markdown, .html, .xml].contains(self) }
    static func resolve(_ value: String) -> EditorSyntax? {
        let name = URL(fileURLWithPath: value).lastPathComponent
            .replacingOccurrences(of: ".sublime-syntax", with: "").lowercased()
        if let direct = allCases.first(where: { $0.rawValue == name || $0.identifier == name || $0.displayName.lowercased() == name }) { return direct }
        switch name {
        case "text", "plain text", "txt": return .plainText
        case "pyw": return .python
        case "mjs", "cjs", "jsx": return .javascript
        case "tsx": return .typescript
        case "markdown", "mdown", "mkd": return .markdown
        case "htm": return .html
        case "h", "cc", "cxx", "hpp": return .cpp
        case "bash", "zsh": return .shell
        case "yaml": return .yaml
        default: return nil
        }
    }
}

struct DocumentSettings: Codable, Equatable {
    var tabSize = 4
    var translateTabsToSpaces = false
    var detectIndentation = true
    var autoIndent = true
    var useTabStops = true
    var smartIndent = true
    var shiftTabUnindent = false
    var syntax: String?
    var lineEnding = LineEnding.lf
    enum CodingKeys: String, CodingKey { case tabSize, translateTabsToSpaces, detectIndentation, autoIndent, useTabStops, smartIndent, shiftTabUnindent, syntax, lineEnding }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tabSize = try c.decodeIfPresent(Int.self, forKey: .tabSize) ?? 4
        translateTabsToSpaces = try c.decodeIfPresent(Bool.self, forKey: .translateTabsToSpaces) ?? false
        detectIndentation = try c.decodeIfPresent(Bool.self, forKey: .detectIndentation) ?? true
        autoIndent = try c.decodeIfPresent(Bool.self, forKey: .autoIndent) ?? true
        useTabStops = try c.decodeIfPresent(Bool.self, forKey: .useTabStops) ?? true
        smartIndent = try c.decodeIfPresent(Bool.self, forKey: .smartIndent) ?? true
        shiftTabUnindent = try c.decodeIfPresent(Bool.self, forKey: .shiftTabUnindent) ?? false
        syntax = try c.decodeIfPresent(String.self, forKey: .syntax)
        lineEnding = try c.decodeIfPresent(LineEnding.self, forKey: .lineEnding) ?? .lf
        try validate()
    }
    func validate() throws {
        guard tabSize > 0 else { throw EditorFailure.invalidEdit("Tab Width 必须为正整数。") }
    }
}

extension TextOperations {
    private static let indentationOutputCapacity = 32 * 1024 * 1024
    private static func error(_ text: String, _ selections: [NSRange], _ message: String) -> TextEditResult {
        TextEditResult(text: text, selections: selections, error: message)
    }
    static func valid(_ text: String, _ selections: [NSRange]) -> Bool {
        let units = Array(text.utf16)
        return selections.allSatisfy { r in r.location >= 0 && r.length >= 0 && r.location <= units.count
            && r.length <= units.count - r.location && isBoundary(r.location, in: units) && isBoundary(NSMaxRange(r), in: units) }
    }
    private static func spaces(_ count: Int) throws -> String {
        guard count >= 0, count <= indentationOutputCapacity else {
            throw EditorFailure.invalidEdit("缩进展开超过单次 32 MiB 文本生成容量；Tab Width 设置已保留。")
        }
        return String(repeating: " ", count: count)
    }
    private static func columns(_ text: String, tabSize: Int) -> Int? {
        guard tabSize > 0 else { return nil }
        var column = 0
        for scalar in text.unicodeScalars {
            let amount = scalar.value == 9 ? tabSize - column % tabSize : 1
            let sum = column.addingReportingOverflow(amount)
            guard !sum.overflow else { return nil }
            column = sum.partialValue
        }
        return column
    }
    static func position(in text: String, utf16Offset: Int, tabSize: Int) -> (line: Int, column: Int)? {
        let source = text as NSString
        return DocumentLineIndex(source).position(in: source, utf16Offset: utf16Offset, tabSize: tabSize)
    }
    private static func linePrefix(_ text: NSString, _ offset: Int) -> String {
        var start = 0, end = 0, contents = 0
        text.getLineStart(&start, end: &end, contentsEnd: &contents, for: NSRange(location: offset, length: 0))
        return text.substring(with: NSRange(location: start, length: offset - start))
    }
    private static func leading(_ text: String) -> String { String(text.prefix { $0 == " " || $0 == "\t" }) }
    // UTF16 offsets for logical CR/LF lines, including an empty final line.
    // A CRLF pair has one start after the complete pair, never a start at LF.
    static func lineStarts(in text: String) -> [Int] {
        DocumentLineIndex(text as NSString).starts
    }
    static func lineStarts(_ text: NSString, _ selections: [NSRange]) -> [Int] {
        let index = DocumentLineIndex(text)
        let allStarts = index.starts
        var selectedStarts = Set<Int>()
        for selection in selections {
            guard selection.location >= 0, selection.length >= 0, selection.location <= text.length,
                  selection.length <= text.length - selection.location else { continue }
            let first = index.lineIndex(at: selection.location)
            let finalOffset = selection.length > 0 ? NSMaxRange(selection) - 1 : selection.location
            let last = index.lineIndex(at: finalOffset)
            for line in first...last { selectedStarts.insert(allStarts[line]) }
        }
        return selectedStarts.sorted()
    }
    static func preserving(_ text: String, _ selections: [NSRange], _ edits: [TextReplacement]) -> TextEditResult {
        let result = apply(in: text, edits: edits)
        guard result.error == nil else { return error(text, selections, result.error!) }
        let ordered = edits.sorted { $0.range.location < $1.range.location }
        func moved(_ point: Int, startOfSelection: Bool) -> Int {
            var delta = 0
            for edit in ordered {
                let begin = edit.range.location, end = NSMaxRange(edit.range), length = (edit.text as NSString).length
                if point < begin { break }
                if point <= end {
                    if point == begin && (startOfSelection || edit.range.length > 0) { return begin + delta }
                    return begin + delta + length
                }
                delta += length - edit.range.length
            }
            return point + delta
        }
        let mapped = selections.map { range -> NSRange in
            let start = moved(range.location, startOfSelection: range.length > 0)
            let end = moved(NSMaxRange(range), startOfSelection: false)
            return NSRange(location: min(start, end), length: abs(end - start))
        }
        return TextEditResult(text: result.text, selections: mapped)
    }
    static func insertTab(in text: String, selections: [NSRange], settings: DocumentSettings, backtab: Bool = false) -> TextEditResult {
        guard valid(text, selections), settings.tabSize > 0 else { return error(text, selections, "无效选区或 Tab Width。") }
        let string = text as NSString
        if backtab && (settings.shiftTabUnindent || selections.allSatisfy({ r in
            let prefix = linePrefix(string, r.location)
            return prefix.allSatisfy { $0 == " " || $0 == "\t" }
                || string.substring(with: r).contains("\n") || string.substring(with: r).contains("\r")
        })) { return indentLines(in: text, selections: selections, settings: settings, outdent: true) }
        do {
            let edits = try selections.map { range -> TextReplacement in
                let prefix = linePrefix(string, range.location)
                guard let column = columns(prefix, tabSize: settings.tabSize) else { throw EditorFailure.invalidEdit("Tab 列数超出整数范围。") }
                let count = settings.useTabStops ? settings.tabSize - column % settings.tabSize : settings.tabSize
                return TextReplacement(range: range, text: settings.translateTabsToSpaces ? try spaces(count) : "\t")
            }
            return apply(in: text, edits: edits)
        } catch { return self.error(text, selections, error.localizedDescription) }
    }
    static func insertNewline(in text: String, selections: [NSRange], settings: DocumentSettings) -> TextEditResult {
        guard valid(text, selections), settings.tabSize > 0 else { return error(text, selections, "无效选区或 Tab Width。") }
        let string = text as NSString
        do {
            let edits = try selections.map { range -> TextReplacement in
                let prefix = linePrefix(string, range.location)
                var indentation = settings.autoIndent ? leading(prefix) : ""
                let trimmed = prefix.trimmingCharacters(in: .whitespaces)
                if settings.autoIndent && settings.smartIndent && (trimmed.hasSuffix("{") || trimmed.hasSuffix("[") || trimmed.hasSuffix("(")) {
                    indentation += settings.translateTabsToSpaces ? try spaces(settings.tabSize) : "\t"
                }
                return TextReplacement(range: range, text: settings.lineEnding.text + indentation)
            }
            return apply(in: text, edits: edits)
        } catch { return self.error(text, selections, error.localizedDescription) }
    }
    static func indentLines(in text: String, selections: [NSRange], settings: DocumentSettings, outdent: Bool = false) -> TextEditResult {
        guard valid(text, selections), settings.tabSize > 0 else { return error(text, selections, "无效选区或 Tab Width。") }
        let string = text as NSString
        do {
            let edits = try lineStarts(string, selections).map { start -> TextReplacement in
                let remaining = string.substring(from: start)
                let prefix = leading(remaining)
                if !outdent { return TextReplacement(range: NSRange(location: start, length: 0), text: settings.translateTabsToSpaces ? try spaces(settings.tabSize) : "\t") }
                if prefix.hasPrefix("\t") { return TextReplacement(range: NSRange(location: start, length: 1), text: "") }
                let count = min(prefix.prefix { $0 == " " }.count, settings.tabSize)
                return TextReplacement(range: NSRange(location: start, length: count), text: "")
            }
            return preserving(text, selections, edits)
        } catch { return self.error(text, selections, error.localizedDescription) }
    }
    static func deleteBackward(in text: String, selections: [NSRange], settings: DocumentSettings) -> TextEditResult {
        guard valid(text, selections), settings.tabSize > 0 else { return error(text, selections, "无效选区或 Tab Width。") }
        let string = text as NSString, units = Array(text.utf16)
        let edits = selections.map { range -> TextReplacement in
            if range.length > 0 || range.location == 0 { return TextReplacement(range: range, text: "") }
            let prefix = linePrefix(string, range.location)
            var count = 1
            if settings.useTabStops && prefix.allSatisfy({ $0 == " " || $0 == "\t" }), prefix.hasSuffix(" "),
               let column = columns(prefix, tabSize: settings.tabSize) {
                count = min(prefix.reversed().prefix { $0 == " " }.count, (column - 1) % settings.tabSize + 1)
            } else if range.location >= 2, units[range.location - 1] == 10, units[range.location - 2] == 13 { count = 2 }
            else if range.location >= 2, (0xdc00...0xdfff).contains(units[range.location - 1]) { count = 2 }
            return TextReplacement(range: NSRange(location: range.location - count, length: count), text: "")
        }
        return apply(in: text, edits: edits)
    }
    static func deleteForward(in text: String, selections: [NSRange], settings: DocumentSettings) -> TextEditResult {
        guard valid(text, selections), settings.tabSize > 0 else { return error(text, selections, "无效选区或 Tab Width。") }
        let string = text as NSString, units = Array(text.utf16)
        let edits = selections.map { range -> TextReplacement in
            if range.length > 0 || range.location == units.count { return TextReplacement(range: range, text: "") }
            let prefix = linePrefix(string, range.location)
            var count = 1
            if settings.useTabStops && prefix.allSatisfy({ $0 == " " || $0 == "\t" }), units[range.location] == 32,
               let column = columns(prefix, tabSize: settings.tabSize) {
                count = min(string.substring(from: range.location).prefix { $0 == " " }.count, settings.tabSize - column % settings.tabSize)
            } else if units[range.location] == 13, range.location + 1 < units.count, units[range.location + 1] == 10 { count = 2 }
            else if (0xd800...0xdbff).contains(units[range.location]) { count = 2 }
            return TextReplacement(range: NSRange(location: range.location, length: count), text: "")
        }
        return apply(in: text, edits: edits)
    }
    static func convertingLineEndings(in text: String, selections: [NSRange], to ending: LineEnding) -> TextEditResult {
        guard valid(text, selections) else { return error(text, selections, "无效 UTF16 选区。") }
        let units = Array(text.utf16)
        var edits: [TextReplacement] = [], index = 0
        while index < units.count {
            if units[index] == 13 || units[index] == 10 {
                let size = units[index] == 13 && index + 1 < units.count && units[index + 1] == 10 ? 2 : 1
                edits.append(TextReplacement(range: NSRange(location: index, length: size), text: ending.text)); index += size
            } else { index += 1 }
        }
        return preserving(text, selections, edits)
    }
    static func detectedIndentation(in text: String, defaults: DocumentSettings) -> DocumentSettings {
        var result = defaults, spacesRows = 0, tabRows = 0, width = 0
        func gcd(_ a: Int, _ b: Int) -> Int { var x = a, y = b; while y != 0 { let r = x % y; x = y; y = r }; return x }
        let source = text as NSString
        var beginning = 0, beginsWithIndent = false
        func considerLine(ending: Int) {
            guard beginsWithIndent, ending > beginning else { return }
            let line = source.substring(with: NSRange(location: beginning, length: ending - beginning))
            let prefix = line.prefix { $0 == " " || $0 == "\t" }
            guard !prefix.isEmpty, prefix.endIndex < line.endIndex else { return }
            if prefix.contains("\t") { tabRows += 1 }
            else { spacesRows += 1; width = gcd(width, prefix.count) }
        }
        var offset = 0, buffer = [unichar](repeating: 0, count: 4096)
        while offset < source.length {
            let count = min(buffer.count, source.length - offset)
            source.getCharacters(&buffer, range: NSRange(location: offset, length: count))
            for index in 0..<count {
                let position = offset + index, unit = buffer[index]
                if position == beginning { beginsWithIndent = unit == 32 || unit == 9 }
                // CharacterSet.newlines, including Unicode newline separators.
                switch unit {
                case 10, 11, 12, 13, 0x85, 0x2028, 0x2029:
                    considerLine(ending: position)
                    beginning = position + 1
                default: break
                }
            }
            offset += count
        }
        considerLine(ending: source.length)
        if spacesRows > tabRows { result.translateTabsToSpaces = true; if width > 0 { result.tabSize = width } }
        else if tabRows > 0 { result.translateTabsToSpaces = false }
        return result
    }
    static func convertIndentation(in text: String, selections: [NSRange], tabSize: Int, toSpaces: Bool) -> TextEditResult {
        guard valid(text, selections), tabSize > 0 else { return error(text, selections, "无效选区或 Tab Width。") }
        let positions = selections.map { (position(in: text, utf16Offset: $0.location, tabSize: tabSize), position(in: text, utf16Offset: NSMaxRange($0), tabSize: tabSize)) }
        guard positions.allSatisfy({ $0.0 != nil && $0.1 != nil }) else { return error(text, selections, "缩进列数溢出，选区未修改。") }
        do {
            var result = "", column = 0, leadingOnly = true, generatedBytes = 0
            func append(_ value: String) throws {
                let count = value.utf8.count
                guard count <= indentationOutputCapacity - generatedBytes else { throw EditorFailure.invalidEdit("缩进转换超过单次 32 MiB 文本生成容量。") }
                generatedBytes += count; result += value
            }
            func appendScalar(_ scalar: UnicodeScalar) throws {
                let count = scalar.value < 0x80 ? 1 : scalar.value < 0x800 ? 2 : scalar.value < 0x10000 ? 3 : 4
                guard count <= indentationOutputCapacity - generatedBytes else { throw EditorFailure.invalidEdit("缩进转换超过单次 32 MiB 文本生成容量。") }
                generatedBytes += count; result.unicodeScalars.append(scalar)
            }
            func advance(_ amount: Int) throws {
                let sum = column.addingReportingOverflow(amount)
                guard !sum.overflow else { throw EditorFailure.invalidEdit("缩进列数溢出。") }
                column = sum.partialValue
            }
            if toSpaces {
                for scalar in text.unicodeScalars {
                    if scalar.value == 9 { let count = tabSize - column % tabSize; try append(try spaces(count)); try advance(count) }
                    else { try appendScalar(scalar); if scalar.value == 10 || scalar.value == 13 { column = 0 } else { try advance(1) } }
                }
            } else {
                var pending = ""
                func flush() throws {
                    guard let width = columns(pending, tabSize: tabSize) else { throw EditorFailure.invalidEdit("缩进列数溢出。") }
                    guard width / tabSize <= indentationOutputCapacity else { throw EditorFailure.invalidEdit("缩进转换超过单次 32 MiB 文本生成容量。") }
                    try append(String(repeating: "\t", count: width / tabSize) + (try spaces(width % tabSize))); pending = ""
                }
                for scalar in text.unicodeScalars {
                    if leadingOnly && (scalar.value == 32 || scalar.value == 9) { pending.unicodeScalars.append(scalar) }
                    else {
                        if leadingOnly { try flush(); leadingOnly = false }
                        try appendScalar(scalar)
                        if scalar.value == 10 || scalar.value == 13 { leadingOnly = true }
                    }
                }
                if !pending.isEmpty { try flush() }
            }
            func point(_ desired: (line: Int, column: Int)?) throws -> Int {
                guard let desired else { throw EditorFailure.invalidEdit("无法恢复溢出的选区列数。") }
                var line = 1, col = 1, offset = 0, previousCR = false
                for scalar in result.unicodeScalars {
                    if line == desired.line && col >= desired.column { return offset }
                    if scalar.value == 13 { if line == desired.line { return offset }; line += 1; col = 1; previousCR = true }
                    else if scalar.value == 10 { if !previousCR { if line == desired.line { return offset }; line += 1 }; col = 1; previousCR = false }
                    else {
                        let amount = scalar.value == 9 ? tabSize - (col - 1) % tabSize : 1
                        let sum = col.addingReportingOverflow(amount)
                        guard !sum.overflow else { throw EditorFailure.invalidEdit("无法恢复溢出的选区列数。") }
                        col = sum.partialValue; previousCR = false
                    }
                    offset += scalar.value > 0xffff ? 2 : 1
                }
                return (result as NSString).length
            }
            let mapped = try positions.map { pair -> NSRange in let a = try point(pair.0), b = try point(pair.1); return NSRange(location: min(a, b), length: abs(b - a)) }
            return TextEditResult(text: result, selections: mapped)
        } catch { return self.error(text, selections, error.localizedDescription) }
    }
}
