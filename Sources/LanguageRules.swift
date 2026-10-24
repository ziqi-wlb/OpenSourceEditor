import Foundation

extension EditorSyntax {
    var commentDelimiters: (open: String, close: String)? {
        switch self {
        case .swift, .javascript, .typescript, .c, .cpp, .rust, .go, .java: return ("//", "")
        case .python, .shell, .yaml, .ruby, .toml: return ("#", "")
        case .sql: return ("--", "")
        case .css: return ("/*", "*/")
        case .html, .xml, .markdown: return ("<!--", "-->")
        case .json, .plainText: return nil
        }
    }
    var supportsHighlighting: Bool { self != .plainText }
    var keywordPattern: String {
        switch self {
        case .sql: return #"(?i)\b(?:select|from|where|join|inner|left|right|outer|on|as|and|or|not|null|is|in|exists|distinct|group|by|having|order|asc|desc|limit|offset|insert|into|values|update|set|delete|create|alter|drop|table|index|primary|key|foreign|references|begin|commit|rollback|with|union|all|case|when|then|else|end)\b"#
        case .json: return #"\b(?:true|false|null)\b"#
        case .markdown: return #"(?m)^\s{0,3}#{1,6}\s+.*$"#
        default: return #"\b(?:class|struct|enum|protocol|extension|func|def|function|let|var|const|if|else|elif|for|while|return|import|from|public|private|static|try|catch|throw|throws|async|await|true|false|null|nil|None|True|False|switch|case|break|continue|in|as|new|export|interface|type|fn|impl|use|package)\b"#
        }
    }
    var commentPattern: String? {
        guard let delimiter = commentDelimiters else { return nil }
        if delimiter.open == "//" { return #"(?m)//.*$|/\*[\s\S]*?\*/"# }
        let open = NSRegularExpression.escapedPattern(for: delimiter.open)
        if delimiter.close.isEmpty { return "(?m)" + open + ".*$" }
        return open + "[\\s\\S]*?" + NSRegularExpression.escapedPattern(for: delimiter.close)
    }
    func shouldIndent(_ prefix: String) -> Bool {
        let trimmed = prefix.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("{") || trimmed.hasSuffix("[") || trimmed.hasSuffix("(") { return true }
        guard self == .python else { return false }
        var code = "", quote: Character?, escaped = false
        for character in trimmed {
            if escaped { code.append(character); escaped = false; continue }
            if character == "\\" { code.append(character); escaped = true; continue }
            if let current = quote {
                code.append(character)
                if character == current { quote = nil }
            } else if character == "\"" || character == "'" { quote = character; code.append(character) }
            else if character == "#" { break }
            else { code.append(character) }
        }
        guard quote == nil, code.trimmingCharacters(in: .whitespaces).hasSuffix(":") else { return false }
        return code.range(of: #"^(?:async\s+)?(?:def|class|if|elif|else|for|while|try|except|finally|with|match|case)\b"#, options: .regularExpression) != nil
    }
}
