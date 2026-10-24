import Foundation

struct ProjectScanSummary {
    var files = 0
    var unreadable = 0
    var limited = false
    var cancelled = false
}

/// Shared traversal for Quick Open and project search; no UI object is retained.
enum ProjectFileScanner {
    static let maximumFiles = 50_000
    static let excludedDirectories: Set<String> = ["node_modules", "__pycache__"]
    static func scan(_ root: URL, isCancelled: () -> Bool, visit: (URL) -> Bool) -> ProjectScanSummary {
        var summary = ProjectScanSummary()
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let enumerator = FileManager.default.enumerator(at: canonicalRoot, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) { _, _ in summary.unreadable += 1; return true }
        guard let enumerator else { summary.unreadable += 1; return summary }
        while let file = enumerator.nextObject() as? URL {
            if isCancelled() { summary.cancelled = true; break }
            guard let info = try? file.resourceValues(forKeys: Set(keys)) else { summary.unreadable += 1; continue }
            if info.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if info.isDirectory == true {
                if excludedDirectories.contains(file.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            guard info.isRegularFile == true else { continue }
            if summary.files == maximumFiles { summary.limited = true; break }
            summary.files += 1
            // Enumerator URLs may carry a relative base even for an absolute root.
            // Publish one absolute identity, matching document ownership.
            if !visit(URL(fileURLWithPath: file.path).standardizedFileURL) { summary.limited = true; break }
        }
        return summary
    }
}

final class ProjectIndexOperation: Operation {
    let root: URL
    private(set) var files: [URL] = []
    private(set) var summary = ProjectScanSummary()
    init(_ root: URL) { self.root = root }
    override func main() {
        var found: [URL] = []
        summary = ProjectFileScanner.scan(root, isCancelled: { self.isCancelled }) { found.append($0); return true }
        if !isCancelled { files = found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending } }
    }
}

struct ProjectSearchHit {
    let file: URL
    let range: NSRange
    let matchedText: String
    let line: Int
    let excerpt: String
}

struct ProjectSearchReport {
    var hits: [ProjectSearchHit] = []
    var scan = ProjectScanSummary()
    var searchedFiles = 0
    var skippedFiles = 0
    var readBytes = 0
    var limitReason: String?
}

enum ProjectSearchEngine {
    static let maximumFileBytes = 2 * 1024 * 1024
    static let maximumTotalBytes = 128 * 1024 * 1024
    static let maximumHits = 2_000
    static func search(root: URL, query: String, caseSensitive: Bool, isCancelled: () -> Bool = { false }) -> ProjectSearchReport {
        var report = ProjectSearchReport()
        guard !query.isEmpty else { return report }
        let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        report.scan = ProjectFileScanner.scan(root, isCancelled: isCancelled) { file in
            if isCancelled() { return false }
            guard let metadata = try? file.resourceValues(forKeys: [.fileSizeKey]), let count = metadata.fileSize,
                  count <= maximumFileBytes else { report.skippedFiles += 1; return true }
            if count > maximumTotalBytes - report.readBytes { report.limitReason = "128 MiB read limit"; return false }
            return autoreleasepool {
                guard let data = try? LocalFileData.read(file, maximumBytes: maximumFileBytes),
                      data.count <= maximumTotalBytes - report.readBytes else { report.skippedFiles += 1; return true }
                report.readBytes += data.count
                guard let decoded = try? EditorEncoding.decode(data, using: nil), !decoded.0.contains("\0") else {
                    report.skippedFiles += 1; return true
                }
                report.searchedFiles += 1
                let text = decoded.0 as NSString
                var offset = 0
                var index: DocumentLineIndex?
                while offset < text.length {
                    if isCancelled() { return false }
                    let range = text.range(of: query, options: options, range: NSRange(location: offset, length: text.length - offset))
                    if range.location == NSNotFound { break }
                    if report.hits.count == maximumHits { report.limitReason = "2,000 match limit"; return false }
                    if index == nil { index = DocumentLineIndex(text) }
                    let line = index!.lineIndex(at: range.location)
                    let lineStart = index!.starts[line]
                    let end = line + 1 < index!.starts.count ? index!.starts[line + 1] : text.length
                    let lineText = text.substring(with: NSRange(location: lineStart, length: end - lineStart))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    report.hits.append(ProjectSearchHit(file: file, range: range, matchedText: text.substring(with: range),
                        line: line + 1, excerpt: String(lineText.prefix(160))))
                    offset = NSMaxRange(range)
                }
                return true
            }
        }
        if isCancelled() { report.scan.cancelled = true }
        if report.scan.limited && report.limitReason == nil { report.limitReason = "50,000 file limit" }
        report.hits.sort { $0.file.path == $1.file.path ? $0.range.location < $1.range.location : $0.file.path.localizedStandardCompare($1.file.path) == .orderedAscending }
        return report
    }
}

final class ProjectSearchOperation: Operation {
    let root: URL
    let query: String
    let caseSensitive: Bool
    private(set) var report: ProjectSearchReport?
    init(root: URL, query: String, caseSensitive: Bool) { self.root = root; self.query = query; self.caseSensitive = caseSensitive }
    override func main() {
        guard !isCancelled else { return }
        report = ProjectSearchEngine.search(root: root, query: query, caseSensitive: caseSensitive, isCancelled: { self.isCancelled })
    }
}
