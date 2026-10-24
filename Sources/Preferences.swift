import Foundation

// JSON-with-comments is parsed once here; strings (including URLs) retain their bytes.
enum SettingsJSON {
    static func normalized(_ data: Data) throws -> Data {
        guard data.count <= 1024 * 1024, String(data: data, encoding: .utf8) != nil else {
            throw EditorFailure.invalidEdit("Settings must be UTF-8 and no larger than 1 MiB.")
        }
        let input = Array(data)
        var output = input
        var i = 0, inString = false, escaped = false
        while i < input.count {
            let byte = input[i]
            if inString {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { inString = false }
                i += 1; continue
            }
            if byte == 34 { inString = true; i += 1; continue }
            guard byte == 47, i + 1 < input.count else { i += 1; continue }
            if input[i + 1] == 47 {
                while i < input.count, input[i] != 10, input[i] != 13 { output[i] = 32; i += 1 }
            } else if input[i + 1] == 42 {
                output[i] = 32; output[i + 1] = 32; i += 2
                var closed = false
                while i < input.count {
                    if input[i] == 42, i + 1 < input.count, input[i + 1] == 47 {
                        output[i] = 32; output[i + 1] = 32; i += 2; closed = true; break
                    }
                    if input[i] != 10, input[i] != 13 { output[i] = 32 }
                    i += 1
                }
                guard closed else { throw EditorFailure.invalidEdit("Unterminated settings comment.") }
            } else { i += 1 }
        }
        guard !inString else { throw EditorFailure.invalidEdit("Unterminated settings string.") }
        inString = false; escaped = false
        func whitespace(_ byte: UInt8) -> Bool { byte == 32 || byte == 9 || byte == 10 || byte == 13 }
        for index in output.indices {
            let byte = output[index]
            if inString {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { inString = false }
            } else if byte == 34 { inString = true }
            else if byte == 44 {
                var next = index + 1, previous = index - 1
                while next < output.count, whitespace(output[next]) { next += 1 }
                while previous >= 0, whitespace(output[previous]) { previous -= 1 }
                if next < output.count, [UInt8(93), UInt8(125)].contains(output[next]), previous >= 0,
                   ![UInt8(91), UInt8(123), UInt8(44), UInt8(58)].contains(output[previous]) { output[index] = 32 }
            }
        }
        return Data(output)
    }
}
