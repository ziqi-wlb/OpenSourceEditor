import Foundation

/// Whole-file lexical matches preserve multiline context; panes paint only the
/// matches intersecting their viewport. No text or AppKit objects are retained.
struct SyntaxHighlights {
    let groups: [[NSRange]]
    private static let expressions: [EditorSyntax: [NSRegularExpression?]] = Dictionary(uniqueKeysWithValues: EditorSyntax.allCases.map { language in
        let patterns: [String?] = [language.keywordPattern, #"\b\d+(?:\.\d+)?\b"#,
                                  #"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#, language.commentPattern]
        return (language, patterns.map { $0.map { try! NSRegularExpression(pattern: $0) } })
    })
    static let supported = Set(EditorSyntax.allCases.filter(\.supportsHighlighting).map(\.identifier))

    init(text: String, syntax: String) {
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard range.length > 0, range.length <= 2_000_000, let language = EditorSyntax.resolve(syntax), language.supportsHighlighting else { groups = []; return }
        groups = Self.expressions[language]!.map { $0?.matches(in: text, range: range).map(\.range) ?? [] }
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
