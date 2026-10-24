import Foundation
import Darwin

struct ProjectFileOperations {
    let root: URL
    private func member(_ url: URL) throws -> URL {
        // Resolve the parent, not the final entry: trashing a link must never
        // trash its target. Directories followed through links stay in scope.
        let value = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent)
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        guard value.path.hasPrefix(base.path + "/") else { throw EditorFailure.invalidEdit("Choose an item inside the project, not the project root.") }
        return value
    }
    static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
              !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }), name.utf8.count <= 255 else {
            throw EditorFailure.invalidEdit("Enter a single filename, without separators or control characters (maximum 255 UTF-8 bytes).")
        }
    }
    func create(in parent: URL, name: String, directory: Bool) throws -> URL {
        try Self.validateName(name)
        let target = try member(parent.appendingPathComponent(name))
        guard !FileManager.default.fileExists(atPath: target.path) else { throw EditorFailure.destinationExists }
        if directory { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false) }
        else { try Data().write(to: target, options: .withoutOverwriting) }
        return target
    }
    func move(_ source: URL, to destination: URL) throws -> URL {
        let source = try member(source), destination = try member(destination)
        guard source != destination else { return source }
        guard !destination.path.hasPrefix(source.path + "/") else { throw EditorFailure.invalidEdit("Cannot move a folder into itself.") }
        if FileManager.default.fileExists(atPath: destination.path) {
            var a = stat(), b = stat()
            guard source.deletingLastPathComponent() == destination.deletingLastPathComponent(),
                  source.lastPathComponent.caseInsensitiveCompare(destination.lastPathComponent) == .orderedSame,
                  lstat(source.path, &a) == 0, lstat(destination.path, &b) == 0,
                  a.st_dev == b.st_dev, a.st_ino == b.st_ino else { throw EditorFailure.destinationExists }
            // Case-insensitive volumes need a temporary sibling. Never overwrite
            // a separate destination, and roll back if the second move fails.
            let temporary = source.deletingLastPathComponent().appendingPathComponent(".source-editor-rename-" + UUID().uuidString)
            try FileManager.default.moveItem(at: source, to: temporary)
            do { try FileManager.default.moveItem(at: temporary, to: destination) }
            catch {
                do { try FileManager.default.moveItem(at: temporary, to: source) }
                catch { throw EditorFailure.invalidEdit("Rename failed; the original item remains at " + temporary.path) }
                throw error
            }
            return destination
        }
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }
    @discardableResult func trash(_ source: URL) throws -> URL? {
        let value = try member(source)
        var destination: NSURL?
        try FileManager.default.trashItem(at: value, resultingItemURL: &destination)
        return destination as URL?
    }
    static func rebase(_ url: URL, from source: URL, to destination: URL) -> URL? {
        let parts = url.standardizedFileURL.pathComponents, old = source.standardizedFileURL.pathComponents
        guard parts.starts(with: old) else { return nil }
        return parts.dropFirst(old.count).reduce(destination) { $0.appendingPathComponent($1) }
    }
}
