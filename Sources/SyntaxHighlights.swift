import Foundation

/// Whole-file lexical matches preserve multiline context; panes paint only the
/// matches intersecting their viewport. No text or AppKit objects are retained.
struct SyntaxHighlights {
    let groups: [[NSRange]]
    private static let patterns = [
        #"\b(?:class|struct|enum|protocol|extension|func|def|function|let|var|const|if|else|elif|for|while|return|import|from|public|private|static|try|catch|throw|throws|async|await|true|false|null|nil|None|True|False|switch|case|break|continue|in|as|new|export|interface|type|fn|impl|use|package)\b"#,
        #"\b\d+(?:\.\d+)?\b"#,
        #"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#,
        #"(?m)//.*$|/\*[\s\S]*?\*/"#,
        #"(?m)#.*$"#,
    ]
    private static let expressions = patterns.map { try! NSRegularExpression(pattern: $0) }
    static let supported = Set(["swift", "py", "js", "jsx", "ts", "tsx", "json", "c", "h", "cpp", "hpp", "m", "mm", "rs", "go", "sh", "rb", "java", "css", "html", "xml", "md", "yaml", "yml", "toml"])

    init(text: String, syntax: String) {
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard range.length > 0, range.length <= 2_000_000, Self.supported.contains(syntax) else { groups = []; return }
        let hashComments = ["py", "sh", "rb", "yaml", "yml", "toml"].contains(syntax)
        groups = [0, 1, 2, hashComments ? 4 : 3].map { index in
            Self.expressions[index].matches(in: text, range: range).map(\.range)
        }
    }

    /// Return only the visible intersection. A multiline comment can span the
    /// entire file, but painting its offscreen extent would force full layout.
    func matches(in range: NSRange, group: Int) -> [NSRange] {
        guard groups.indices.contains(group), range.length > 0 else { return [] }
        let tokens = groups[group]
        var lower = 0, upper = tokens.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if NSMaxRange(tokens[middle]) <= range.location { lower = middle + 1 } else { upper = middle }
        }
        let first = lower
        while lower < tokens.count && tokens[lower].location < NSMaxRange(range) { lower += 1 }
        return tokens[first..<lower].map { NSIntersectionRange($0, range) }.filter { $0.length > 0 }
    }
}
