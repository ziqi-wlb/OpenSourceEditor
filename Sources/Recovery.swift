import Foundation

/// One workspace owns one randomly named snapshot. All writes and the final
/// removal use the same serial queue, so a late write cannot resurrect it.
final class EditorRecovery {
    static let maximumUTF16 = 4 * 1024 * 1024
    static var activeURLs: Set<URL> = [] // Main-thread registry for live workspaces.
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Source Editor/Recovery", isDirectory: true)
    }
    let url: URL
    private let queue = DispatchQueue(label: "SourceEditor.Recovery", qos: .utility)
    private(set) var isWriting = false
    private(set) var isFinishing = false
    init(directory: URL = defaultDirectory) {
        url = directory.appendingPathComponent(UUID().uuidString + ".json").standardizedFileURL
        Self.activeURLs.insert(url)
    }
    func write(_ session: EditorSession?, completion: @escaping (Error?) -> Void) {
        guard !isWriting, !isFinishing else { return }
        isWriting = true
        let destination = url
        queue.async {
            let outcome: Error?
            do {
                if let session {
                    guard session.documents.count <= 128,
                          session.documents.reduce(0, { $0 + $1.text.utf16.count }) <= Self.maximumUTF16 else {
                        throw EditorFailure.invalidEdit("Auto recovery exceeds 4 million UTF-16 units or 128 modified documents. Save files or use Save Session.")
                    }
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                           attributes: [.posixPermissions: 0o700])
                    try session.save(destination)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                } else if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                outcome = nil
            } catch { outcome = error }
            DispatchQueue.main.async { [self] in isWriting = false; completion(outcome) }
        }
    }
    func finish(completion: @escaping (Error?) -> Void) {
        guard !isFinishing else { return }
        isFinishing = true
        let destination = url
        queue.async {
            var failure: Error?
            do {
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            } catch { failure = error }
            DispatchQueue.main.async {
                Self.activeURLs.remove(destination)
                completion(failure)
            }
        }
    }
}
