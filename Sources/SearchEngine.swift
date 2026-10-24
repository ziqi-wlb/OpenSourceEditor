import Foundation

struct SearchScan {
    let matches: [NSTextCheckingResult]
    let limit: String?
    var ranges: [NSRange] { matches.map(\.range) }
}

enum SearchEngine {
    static let maximumUTF16 = 8_000_000
    static let maximumMatches = 50_000
    static let maximumOutputUTF16 = 16_000_000

    static func scan(in text: String, query: String, regex: Bool = false, caseSensitive: Bool = false,
                     isCancelled: @escaping () -> Bool = { false }) throws -> SearchScan {
        guard !query.isEmpty else { return SearchScan(matches: [], limit: nil) }
        guard query.utf16.count <= 4096 else { throw EditorFailure.invalidEdit("Search query exceeds 4,096 UTF-16 units.") }
        guard (text as NSString).length <= maximumUTF16 else {
            throw EditorFailure.invalidEdit("Search supports up to 8 million UTF-16 units. Narrow the file first.")
        }
        if isCancelled() { return SearchScan(matches: [], limit: "Search cancelled") }
        let expression = try expression(query, regex, caseSensitive)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        var matches: [NSTextCheckingResult] = [], captures = 0, limit: String?
        // Matching callbacks always check the budget. Empty progress callbacks
        // sample every 64 reports to avoid an OS clock call per scanned unit.
        var checkpoints = 0
        // ICU reports progress even during a long failed match; the callback
        // stops backtracking, rather than merely moving an unbounded job off UI.
        expression.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(location: 0, length: (text as NSString).length)) { match, _, stop in
            checkpoints += 1
            if match == nil, checkpoints % 64 != 0 { return }
            if isCancelled() { limit = "Search cancelled"; stop.pointee = true; return }
            if ProcessInfo.processInfo.systemUptime >= deadline { limit = "Search time limit (0.5 s)"; stop.pointee = true; return }
            guard let match else { return }
            if matches.count >= maximumMatches || captures + match.numberOfRanges > 200_000 {
                limit = "Search result limit (50,000 matches / 200,000 capture ranges)"; stop.pointee = true; return
            }
            captures += match.numberOfRanges
            matches.append(match)
        }
        return SearchScan(matches: matches, limit: limit)
    }

    private static func expression(_ query: String, _ regex: Bool, _ caseSensitive: Bool) throws -> NSRegularExpression {
        try NSRegularExpression(pattern: regex ? query : NSRegularExpression.escapedPattern(for: query),
                                options: caseSensitive ? [] : [.caseInsensitive])
    }
    static func find(in text: String, query: String, regex: Bool = false, caseSensitive: Bool = false) throws -> [NSRange] {
        let result = try scan(in: text, query: query, regex: regex, caseSensitive: caseSensitive)
        guard result.limit == nil else { throw EditorFailure.invalidEdit(result.limit!) }
        return result.ranges
    }
    static func replacing(in text: String, query: String, replacement: String,
                          regex: Bool = false, caseSensitive: Bool = false, range: NSRange? = nil,
                          isCancelled: @escaping () -> Bool = { false }) throws -> TextEditResult {
        guard replacement.utf16.count <= 4096 else { throw EditorFailure.invalidEdit("Replacement exceeds 4,096 UTF-16 units.") }
        let result = try scan(in: text, query: query, regex: regex, caseSensitive: caseSensitive, isCancelled: isCancelled)
        guard result.limit == nil else { throw EditorFailure.invalidEdit((result.limit ?? "Incomplete search") + "; replacement was not applied.") }
        guard !query.isEmpty else { return TextEditResult(text: text, selections: []) }
        let expression = try expression(query, regex, caseSensitive)
        let source = text as NSString
        let output = NSMutableString()
        var cursors: [NSRange] = [], offset = 0
        var outputLength = source.length, retained = 0
        let references = regex ? replacement.filter { $0 == "$" }.count : 0
        for match in result.matches where range == nil || match.range == range {
            if isCancelled() { throw CancellationError() }
            // Bound expansion before Foundation allocates a replacement. This
            // conservative bound also covers escaped/invalid capture references.
            let largest = (0..<match.numberOfRanges).map { match.range(at: $0).length }.max() ?? 0
            let expansionBound = replacement.utf16.count + references * largest
            guard expansionBound <= maximumOutputUTF16 - retained else { throw EditorFailure.invalidEdit("Replacement expansion exceeds 16 million UTF-16 units.") }
            let value = regex ? expression.replacementString(for: match, in: text, offset: 0, template: replacement) : replacement
            retained += value.utf16.count
            outputLength += value.utf16.count - match.range.length
            guard retained <= maximumOutputUTF16, outputLength <= maximumOutputUTF16 else { throw EditorFailure.invalidEdit("Replacement output exceeds 16 million UTF-16 units.") }
            guard Range(match.range, in: text) != nil else {
                throw EditorFailure.invalidEdit("Regex splits a Unicode scalar; replacement was not applied.")
            }
            output.append(source.substring(with: NSRange(location: offset, length: match.range.location - offset)))
            output.append(value)
            offset = NSMaxRange(match.range)
            cursors.append(NSRange(location: output.length, length: 0))
        }
        if isCancelled() { throw CancellationError() }
        output.append(source.substring(from: offset))
        return TextEditResult(text: output as String, selections: cursors)
    }
}

final class SearchOperation: Operation {
    let body: (SearchOperation) -> Void
    init(_ body: @escaping (SearchOperation) -> Void) { self.body = body }
    override func main() { if !isCancelled { body(self) } }
}

// Accessed on the main queue. At most one active snapshot and one latest
// snapshot are retained, including when the user changes a query rapidly.
final class LatestSearchWorker {
    private let queue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = 1; q.qualityOfService = .userInitiated; return q }()
    private var active: SearchOperation?
    private var latest: SearchOperation?
    func submit(_ operation: SearchOperation) {
        active?.cancel(); latest?.cancel(); latest = operation
        startLatest()
    }
    private func startLatest() {
        guard active == nil, let operation = latest else { return }
        latest = nil; active = operation
        operation.completionBlock = { [weak self, weak operation] in
            DispatchQueue.main.async {
                guard let self, let operation, self.active === operation else { return }
                self.active = nil; self.startLatest()
            }
        }
        queue.addOperation(operation)
    }
    func cancel() { active?.cancel(); latest?.cancel(); latest = nil }
    deinit { queue.cancelAllOperations() }
}
