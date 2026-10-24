import Foundation

enum LineEditAction: Equatable { case duplicate, delete, moveUp, moveDown }

extension TextOperations {
    /// Logical lines own their terminators. Moving bodies preserves the terminator
    /// at each position, including a final line with no newline.
    static func editLines(in text: String, selections: [NSRange], action: LineEditAction,
                          ending: LineEnding = .lf) -> TextEditResult {
        guard valid(text, selections) else { return TextEditResult(text: text, selections: selections, error: "Invalid UTF-16 selection.") }
        let source = text as NSString
        let starts = DocumentLineIndex(source).starts
        let selected = Set(lineStarts(source, selections))
        var groups: [ClosedRange<Int>] = []
        for index in starts.indices where selected.contains(starts[index]) {
            if let last = groups.last, last.upperBound + 1 == index { groups[groups.count - 1] = last.lowerBound...index }
            else { groups.append(index...index) }
        }
        func end(_ index: Int) -> Int { index + 1 < starts.count ? starts[index + 1] : source.length }
        func row(_ index: Int) -> (body: String, newline: String) {
            let value = source.substring(with: NSRange(location: starts[index], length: end(index) - starts[index]))
            let newline = value.hasSuffix("\r\n") ? "\r\n" : value.hasSuffix("\n") ? "\n" : value.hasSuffix("\r") ? "\r" : ""
            return (String(value.dropLast(newline.count)), newline)
        }
        var edits: [TextReplacement] = []
        var movedPoints: [(NSRange, Int)] = []
        var movedLines: [Int: Int] = [:]
        for group in groups {
            let begin = starts[group.lowerBound], finish = end(group.upperBound)
            let range = NSRange(location: begin, length: finish - begin)
            switch action {
            case .delete: edits.append(TextReplacement(range: range, text: ""))
            case .duplicate:
                let value = source.substring(with: range)
                let needsEnding = row(group.upperBound).newline.isEmpty
                let prefix = needsEnding ? ending.text : ""
                edits.append(TextReplacement(range: NSRange(location: finish, length: 0), text: prefix + value))
                movedPoints.append((range, finish - begin + prefix.utf16.count))
            case .moveUp, .moveDown:
                let up = action == .moveUp
                if up ? group.lowerBound == 0 : group.upperBound == starts.count - 1 { continue }
                let lower = up ? group.lowerBound - 1 : group.lowerBound
                let upper = up ? group.upperBound : group.upperBound + 1
                let indices = up ? Array(group) + [lower] : [upper] + Array(group)
                var replacement = ""
                for (slot, bodyIndex) in zip(lower...upper, indices) {
                    replacement += row(bodyIndex).body + row(slot).newline
                    movedLines[bodyIndex] = slot
                }
                let full = NSRange(location: starts[lower], length: end(upper) - starts[lower])
                edits.append(TextReplacement(range: full, text: replacement))
            }
        }
        let result = preserving(text, selections, edits)
        guard result.error == nil, action != .delete else { return result }
        if action == .moveUp || action == .moveDown {
            let oldIndex = DocumentLineIndex(source), newIndex = DocumentLineIndex(result.text as NSString)
            func mappedPoint(_ point: Int, endOfSelection: Bool) -> Int {
                var line = oldIndex.lineIndex(at: point)
                if endOfSelection, line > 0, point == starts[line], let moved = movedLines[line - 1] {
                    return moved + 1 < newIndex.starts.count ? newIndex.starts[moved + 1] : result.text.utf16.count
                }
                let column = min(point - starts[line], row(line).body.utf16.count)
                line = movedLines[line] ?? line
                return newIndex.starts[line] + column
            }
            return TextEditResult(text: result.text, selections: selections.map {
                let first = mappedPoint($0.location, endOfSelection: false)
                let last = mappedPoint(NSMaxRange($0), endOfSelection: $0.length > 0)
                return NSRange(location: min(first, last), length: abs(last - first))
            })
        }
        // Duplicated lines select their new copies.
        let mapped = selections.map { selection -> NSRange in
            guard let move = movedPoints.first(where: { selection.location >= $0.0.location && selection.location <= NSMaxRange($0.0)
                && NSMaxRange(selection) <= NSMaxRange($0.0) }) else { return selection }
            let earlier = edits.filter { $0.range.location <= move.0.location }.reduce(0) { $0 + $1.text.utf16.count }
            return NSRange(location: selection.location + move.1 + earlier, length: selection.length)
        }
        return TextEditResult(text: result.text, selections: mapped)
    }

    static func toggleComment(in text: String, selections: [NSRange], syntax: EditorSyntax) -> TextEditResult {
        guard valid(text, selections) else { return TextEditResult(text: text, selections: selections, error: "Invalid UTF-16 selection.") }
        let token: String, closing: String
        switch syntax {
        case .swift, .javascript, .typescript, .c, .cpp, .rust, .go: token = "//"; closing = ""
        case .python, .shell, .yaml: token = "#"; closing = ""
        case .sql: token = "--"; closing = ""
        case .css: token = "/*"; closing = "*/"
        case .html, .xml, .markdown: token = "<!--"; closing = "-->"
        case .json, .plainText: return TextEditResult(text: text, selections: selections, error: "This syntax has no supported comment form.")
        }
        let source = text as NSString
        let lineIndex = DocumentLineIndex(source)
        let starts = lineIndex.starts
        let selected = lineStarts(source, selections)
        let rows = selected.compactMap { start -> (NSRange, String)? in
            let index = lineIndex.lineIndex(at: start)
            let end = index + 1 < starts.count ? starts[index + 1] : source.length
            let line = source.substring(with: NSRange(location: start, length: end - start))
            let indentation = line.prefix { $0 == " " || $0 == "\t" }.utf16.count
            let body = line.dropFirst(indentation).trimmingCharacters(in: .newlines)
            guard !body.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return (NSRange(location: start + indentation, length: body.utf16.count), body)
        }
        let uncomment = !rows.isEmpty && rows.allSatisfy { $0.1.hasPrefix(token) && (closing.isEmpty || $0.1.hasSuffix(closing)) }
        if !uncomment, !closing.isEmpty, rows.contains(where: { $0.1.contains(closing) || (token == "<!--" && $0.1.contains("--")) }) {
            return TextEditResult(text: text, selections: selections, error: "The selected text contains a block-comment delimiter. Choose a smaller selection.")
        }
        let edits = rows.flatMap { range, body -> [TextReplacement] in
            if uncomment {
                let prefix = token.utf16.count + (body.dropFirst(token.count).hasPrefix(" ") ? 1 : 0)
                var changes = [TextReplacement(range: NSRange(location: range.location, length: prefix), text: "")]
                if !closing.isEmpty {
                    let suffix = closing.utf16.count + (body.dropLast(closing.count).hasSuffix(" ") ? 1 : 0)
                    // A comment consisting only of delimiters has adjacent edits.
                    changes.append(TextReplacement(range: NSRange(location: NSMaxRange(range) - suffix, length: suffix), text: ""))
                }
                return changes
            }
            var changes = [TextReplacement(range: NSRange(location: range.location, length: 0), text: token + " ")]
            if !closing.isEmpty { changes.append(TextReplacement(range: NSRange(location: NSMaxRange(range), length: 0), text: " " + closing)) }
            return changes
        }
        return preserving(text, selections, edits)
    }
}
