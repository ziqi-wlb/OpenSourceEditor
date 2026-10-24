import Foundation

/// Logical CR/LF line offsets. Shared by a document's status and split rulers.
/// Stores offsets only; it never retains a second copy of the document text.
struct DocumentLineIndex {
    let starts: [Int]

    init(_ text: NSString) {
        var result = [0], previousCR = false
        var buffer = [unichar](repeating: 0, count: 4096)
        var offset = 0
        while offset < text.length {
            let count = min(buffer.count, text.length - offset)
            text.getCharacters(&buffer, range: NSRange(location: offset, length: count))
            for index in 0..<count {
                let unit = buffer[index]
                if unit == 13 { result.append(offset + index + 1); previousCR = true }
                else if unit == 10 {
                    if previousCR { result[result.count - 1] = offset + index + 1 }
                    else { result.append(offset + index + 1) }
                    previousCR = false
                } else { previousCR = false }
            }
            offset += count
        }
        starts = result
    }

    func lineIndex(at offset: Int) -> Int {
        var lower = 0, upper = starts.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if starts[middle] <= offset { lower = middle + 1 } else { upper = middle }
        }
        return max(0, lower - 1)
    }

    func position(in text: NSString, utf16Offset offset: Int, tabSize: Int) -> (line: Int, column: Int)? {
        guard tabSize > 0, offset >= 0, offset <= text.length else { return nil }
        if offset > 0 && offset < text.length {
            let previous = text.character(at: offset - 1), next = text.character(at: offset)
            if UTF16.isLeadSurrogate(previous) && UTF16.isTrailSurrogate(next) { return nil }
            // The cursor between CR and LF has already entered the next line.
            if previous == 13 && next == 10 { return (lineIndex(at: offset) + 2, 1) }
        }
        let line = lineIndex(at: offset)
        var cursor = starts[line], column = 0
        var buffer = [unichar](repeating: 0, count: min(4096, offset - cursor))
        var previousLead = false
        while cursor < offset {
            let count = min(buffer.count, offset - cursor)
            text.getCharacters(&buffer, range: NSRange(location: cursor, length: count))
            for index in 0..<count {
                let unit = buffer[index]
                if !(previousLead && UTF16.isTrailSurrogate(unit)) {
                    let amount = unit == 9 ? tabSize - column % tabSize : 1
                    let sum = column.addingReportingOverflow(amount)
                    guard !sum.overflow else { return nil }
                    column = sum.partialValue
                }
                previousLead = UTF16.isLeadSurrogate(unit)
            }
            cursor += count
        }
        let oneBased = column.addingReportingOverflow(1)
        return oneBased.overflow ? nil : (line + 1, oneBased.partialValue)
    }
}
