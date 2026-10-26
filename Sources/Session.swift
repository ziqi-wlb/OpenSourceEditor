import Foundation

struct EditorSession: Codable {
    struct Document: Codable {
        var path: String?
        var diskDigest: String?
        var text: String
        var selections: [[Int]]
        var settings: DocumentSettings?
        var encoding: EditorEncoding?
        var diskEncoding: EditorEncoding?
        var isImage: Bool? = nil
        init(document: EditorDocument, ranges: [NSRange]) {
            path = document.fileURL?.path; diskDigest = document.diskDigestHex
            text = document.storage.string; selections = ranges.map { [$0.location, $0.length] }
            settings = document.settings; encoding = document.encoding; diskEncoding = document.diskEncoding
            isImage = document.isTextDocument ? nil : true
        }
        func restore() throws -> (EditorDocument, [NSRange]) {
            if isImage == true {
                guard let path else { throw EditorFailure.invalidEdit("Image session entry has no file path.") }
                let document = try EditorDocument.open(URL(fileURLWithPath: path), asImage: true)
                guard !document.isTextDocument else { throw EditorFailure.invalidEdit("The saved image path no longer identifies an image.") }
                return (document, [NSRange(location: 0, length: 0)])
            }
            let document: EditorDocument
            if let path, let diskDigest, let opened = try? EditorDocument.open(URL(fileURLWithPath: path), encoding: diskEncoding, settings: settings ?? DocumentSettings()), opened.isTextDocument, opened.diskDigestHex == diskDigest {
                document = opened
            } else {
                // Missing or changed original files recover into an untitled buffer.
                // Recovery must never adopt a new disk baseline for old text.
                document = EditorDocument()
            }
            document.restoreSessionState(text: text, encoding: encoding, settings: settings)
            let ranges = selections.compactMap { r -> NSRange? in
                guard r.count == 2, r[0] >= 0, r[1] >= 0, r[0] <= (text as NSString).length,
                      r[1] <= (text as NSString).length - r[0], Range(NSRange(location: r[0], length: r[1]), in: text) != nil else { return nil }
                return NSRange(location: r[0], length: r[1])
            }
            return (document, ranges.isEmpty ? [NSRange(location: 0, length: 0)] : ranges)
        }
    }
    var version = 1
    var projectPath: String?
    var selectedIndex: Int
    var split: Bool
    var documents: [Document]
    // Optional additions keep existing Save Session and crash snapshots readable.
    var closedNormally: Bool? = nil
    var workspace: SavedWorkspace? = nil
    var editorLayout: SavedEditorLayout? = nil
    static func load(_ url: URL) throws -> EditorSession {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let data = try file.read(upToCount: 32 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 32 * 1024 * 1024 else { throw EditorFailure.invalidEdit("Session exceeds 32 MiB.") }
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.version == 1, !result.documents.isEmpty, result.documents.count <= 256,
              result.documents.indices.contains(result.selectedIndex) else { throw EditorFailure.invalidEdit("Invalid or unsupported session.") }
        if let workspace = result.workspace { try SavedDesktop(workspaces: [workspace]).validate() }
        try result.editorLayout?.validate()
        return result
    }
    func save(_ url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= 32 * 1024 * 1024 else { throw EditorFailure.invalidEdit("Session exceeds 32 MiB.") }
        try data.write(to: url, options: .atomic)
    }
}

// Preserve original JSON values, including unknown fields, when round-tripping
// a project. Only a single local folder is currently exposed by the window.
struct EditorProject {
    let sourceURL: URL
    private(set) var values: [String: Any]
    let folderURL: URL
    init(folderURL: URL) {
        self.folderURL = folderURL.standardizedFileURL
        sourceURL = self.folderURL.appendingPathComponent("untitled.source-project")
        values = ["folders": [["path": self.folderURL.path]]]
    }
    private init(sourceURL: URL, values: [String: Any], folderURL: URL) {
        self.sourceURL = sourceURL; self.values = values; self.folderURL = folderURL
    }
    static func load(_ url: URL) throws -> EditorProject {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let data = try file.read(upToCount: 1024 * 1024 + 1) ?? Data()
        guard data.count <= 1024 * 1024, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let folders = object["folders"] as? [[String: Any]], folders.count == 1,
              let path = folders[0]["path"] as? String else {
            throw EditorFailure.invalidEdit("Project needs one folders entry with a path. Multi-root projects are not yet supported.")
        }
        let folder = URL(fileURLWithPath: path, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
        guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { throw EditorFailure.invalidEdit("Project folder does not exist.") }
        return EditorProject(sourceURL: url, values: object, folderURL: folder)
    }
    func save(_ url: URL) throws {
        var object = values
        // Relative paths must retain their referent after Save As.
        if url.deletingLastPathComponent().standardizedFileURL != sourceURL.deletingLastPathComponent().standardizedFileURL,
           var folders = object["folders"] as? [[String: Any]], !folders.isEmpty {
            folders[0]["path"] = folderURL.path; object["folders"] = folders
        }
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
}
