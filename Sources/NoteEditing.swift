import Foundation

enum NoteEditing {
    private static let list = try! NSRegularExpression(pattern: #"^(\s*)((?:>\s*)*)([-+*]|\d+[.)])\s+(?:\[([ xX])\]\s+)?(.*)$"#)
    private static let task = try! NSRegularExpression(pattern: #"^(\s*(?:>\s*)*(?:[-+*]|\d+[.)])\s+\[)([ xX])(\]\s*)"#)
    private static let fence = try! NSRegularExpression(pattern: #"^\s{0,3}(?:>\s*)?(`{3,}|~{3,})"#)

    // Visit the prefix once for all cursors; retain only requested row contexts.
    private static func fencedRows(_ source: NSString, rows: Set<Int>) -> Set<Int> {
        guard source.length <= 2_000_000, let last = rows.max() else { return [] }
        var result = Set<Int>(), start = 0
        var open: (Character, Int)?
        while start <= last, start < source.length {
            let range = source.lineRange(for: NSRange(location: start, length: 0))
            let line = source.substring(with: range), value = line as NSString
            if open != nil, rows.contains(start) { result.insert(start) }
            if let match = fence.firstMatch(in: line, range: NSRange(location: 0, length: value.length)) {
                let marker = value.substring(with: match.range(at: 1))
                let tail = value.substring(from: NSMaxRange(match.range)).trimmingCharacters(in: .whitespacesAndNewlines)
                if let current = open {
                    if marker.first == current.0, marker.count >= current.1, tail.isEmpty { open = nil }
                } else if let first = marker.first, first != "`" || !tail.contains("`") {
                    open = (first, marker.count)
                    if rows.contains(start) { result.insert(start) }
                }
            }
            start = NSMaxRange(range)
        }
        if open != nil, rows.contains(source.length) { result.insert(source.length) }
        return result
    }

    static func newline(in text: String, selections: [NSRange], settings: DocumentSettings) -> TextEditResult {
        guard TextOperations.valid(text, selections) else { return TextEditResult(text: text, selections: selections, error: "Invalid selection.") }
        let source = text as NSString
        let rows = Set(selections.map { source.lineRange(for: NSRange(location: $0.location, length: 0)).location })
        let codeRows = fencedRows(source, rows: rows)
        var edits: [TextReplacement] = []
        for selection in selections {
            let row = source.lineRange(for: NSRange(location: selection.location, length: 0))
            let prefix = source.substring(with: NSRange(location: row.location, length: selection.location - row.location))
            var quote = ""
            if source.length > 2_000_000 || codeRows.contains(row.location) || NSMaxRange(selection) > NSMaxRange(row) {
                let indentation = prefix.prefix { $0 == " " || $0 == "\t" }
                edits.append(.init(range: selection, text: settings.lineEnding.text + (settings.autoIndent ? String(indentation) : "")))
                continue
            }
            let value = prefix as NSString
            if let match = list.firstMatch(in: prefix, range: NSRange(location: 0, length: value.length)) {
                let indent = value.substring(with: match.range(at: 1))
                quote = value.substring(with: match.range(at: 2))
                var marker = value.substring(with: match.range(at: 3))
                let body = value.substring(with: match.range(at: 5))
                let rest = source.substring(with: NSRange(location: NSMaxRange(selection), length: max(0, NSMaxRange(row) - NSMaxRange(selection))))
                if body.trimmingCharacters(in: .whitespaces).isEmpty && rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    edits.append(.init(range: NSRange(location: row.location, length: NSMaxRange(selection) - row.location), text: indent + quote + settings.lineEnding.text))
                    continue
                }
                if let number = Int(marker.dropLast()), number < Int.max { marker = String(number + 1) + String(marker.suffix(1)) }
                let checkbox = match.range(at: 4).location == NSNotFound ? "" : "[ ] "
                edits.append(.init(range: selection, text: settings.lineEnding.text + indent + quote + marker + " " + checkbox))
            } else if let range = prefix.range(of: #"^\s*(?:>\s*)+"#, options: .regularExpression) {
                quote = String(prefix[range])
                if prefix[range.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty {
                    edits.append(.init(range: NSRange(location: row.location, length: NSMaxRange(selection) - row.location), text: settings.lineEnding.text))
                } else { edits.append(.init(range: selection, text: settings.lineEnding.text + quote)) }
            } else {
                let indent = prefix.prefix { $0 == " " || $0 == "\t" }
                edits.append(.init(range: selection, text: settings.lineEnding.text + (settings.autoIndent ? String(indent) : "")))
            }
        }
        return TextOperations.apply(in: text, edits: edits)
    }

    static func toggleTasks(in text: String, selections: [NSRange]) -> TextEditResult {
        guard TextOperations.valid(text, selections) else { return TextEditResult(text: text, selections: selections, error: "Invalid selection.") }
        let source = text as NSString
        let rows = TextOperations.lineStarts(source, selections)
        guard source.length <= 2_000_000 else { return TextEditResult(text: text, selections: selections, error: "Task editing supports up to 2 million UTF-16 units.") }
        let codeRows = fencedRows(source, rows: Set(rows))
        let matches = rows.compactMap { start -> NSRange? in
            guard !codeRows.contains(start) else { return nil }
            let row = source.lineRange(for: NSRange(location: start, length: 0))
            let line = source.substring(with: row)
            guard let match = task.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else { return nil }
            return NSRange(location: row.location + match.range(at: 2).location, length: 1)
        }
        guard !matches.isEmpty else { return TextEditResult(text: text, selections: selections, error: "Select a Markdown task list item: - [ ] task") }
        let markDone = matches.contains { source.substring(with: $0) == " " }
        return TextOperations.preserving(text, selections, matches.map { .init(range: $0, text: markDone ? "x" : " ") })
    }
}
