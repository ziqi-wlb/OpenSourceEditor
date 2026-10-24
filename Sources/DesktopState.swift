import Foundation

// Normal restart state contains file identities and presentation only. Unsaved
// text belongs to EditorRecovery; a discarded buffer must not return on restart.
struct SavedWorkspace: Codable {
    struct File: Codable {
        var path: String
        var settings: DocumentSettings
        var encoding: EditorEncoding
        var selections: [[Int]]
        var markdownMode: String
    }
    var files: [File]
    var selectedPath: String?
    var projectPath: String?
    var split: Bool
    var sidebarVisible: Bool
    var frame: [Double]
    var scrollY: Double
    var recoveryFileName: String? = nil
}

struct SavedDesktop: Codable {
    var version = 1
    var workspaces: [SavedWorkspace]
    func validate() throws {
        guard version == 1, workspaces.count <= 32,
              workspaces.reduce(0, { $0 + $1.files.count }) <= 256 else {
            throw EditorFailure.invalidEdit("Workspace state exceeds 32 windows or 256 files.")
        }
        for workspace in workspaces {
            if let name = workspace.recoveryFileName,
               (name != URL(fileURLWithPath: name).lastPathComponent || !name.hasSuffix(".json")) {
                throw EditorFailure.invalidEdit("Invalid recovery file identity.")
            }
            guard workspace.frame.count == 4, workspace.frame.allSatisfy(\.isFinite),
                  workspace.frame[2] > 0, workspace.frame[3] > 0,
                  workspace.scrollY.isFinite, workspace.scrollY >= 0,
                  workspace.projectPath.map({ $0.hasPrefix("/") }) ?? true else {
                throw EditorFailure.invalidEdit("Invalid workspace geometry or project path.")
            }
            var paths = Set<String>()
            for file in workspace.files {
                guard file.path.hasPrefix("/"), paths.insert(file.path).inserted,
                      file.selections.count <= 4096,
                      file.selections.allSatisfy({ $0.count == 2 && $0[0] >= 0 && $0[1] >= 0 }),
                      ["edit", "preview", "sideBySide"].contains(file.markdownMode) else {
                    throw EditorFailure.invalidEdit("Invalid workspace file state.")
                }
                try file.settings.validate()
            }
        }
    }
}

final class EditorDesktopStore {
    let directory: URL
    static var production: EditorDesktopStore? {
        #if EDITOR_TESTS
        return nil
        #else
        guard Bundle.main.bundleIdentifier == "org.sourceeditor.SourceEditor" else { return nil }
        return EditorDesktopStore(directory: EditorRecovery.defaultDirectory.deletingLastPathComponent())
        #endif
    }
    init(directory: URL) { self.directory = directory }
    func loadConfiguration() throws -> EditorConfiguration? {
        let url = directory.appendingPathComponent("preferences.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try EditorConfiguration.parse(LocalFileData.read(url, maximumBytes: 1024 * 1024))
    }
    func saveConfiguration(_ value: EditorConfiguration) throws {
        try write(JSONEncoder().encode(value), name: "preferences.json")
    }
    func loadDesktop() throws -> SavedDesktop? {
        let url = directory.appendingPathComponent("workspace.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try JSONDecoder().decode(SavedDesktop.self, from: LocalFileData.read(url, maximumBytes: 1024 * 1024))
        try value.validate()
        return value
    }
    func saveDesktop(_ value: SavedDesktop) throws {
        try value.validate()
        try write(JSONEncoder().encode(value), name: "workspace.json")
    }
    private func write(_ data: Data, name: String) throws {
        guard data.count <= 1024 * 1024 else { throw EditorFailure.invalidEdit("Preferences/workspace exceeds 1 MiB.") }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = directory.appendingPathComponent(name)
        if manager.fileExists(atPath: destination.path) {
            // Preserve even malformed previous data before replacing our file.
            let backup = directory.appendingPathComponent(name + ".previous")
            if manager.fileExists(atPath: backup.path) { try manager.removeItem(at: backup) }
            try manager.copyItem(at: destination, to: backup)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        try data.write(to: destination, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
}

struct RecoveryCandidate {
    let url: URL
    let modified: Date
    let bytes: Int
    static func discover(in directory: URL = EditorRecovery.defaultDirectory) -> [RecoveryCandidate] {
        guard let enumerator = FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return [] }
        var result: [RecoveryCandidate] = []
        for case let url as URL in enumerator {
            guard result.count < 128 else { break }
            guard url.pathExtension == "json", !EditorRecovery.activeURLs.contains(url.standardizedFileURL),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            result.append(.init(url: url, modified: values.contentModificationDate ?? .distantPast, bytes: values.fileSize ?? 0))
        }
        return result.sorted { $0.modified > $1.modified }
    }
}
