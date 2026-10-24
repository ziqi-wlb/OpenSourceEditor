import Foundation

/// One workspace owns one randomly named snapshot. All writes and the final
/// retention/discard use the same serial queue. Final close writes supersede
/// timer snapshots; failed finalization leaves the live owner available to retry.
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
    private var pendingSession: EditorSession?
    private var hasPendingWrite = false
    private var pendingCompletions: [(Error?) -> Void] = []
    private var finishRequest: (session: EditorSession?, preserve: Bool, completion: (Error?) -> Void)?
    init(directory: URL = defaultDirectory) {
        url = directory.appendingPathComponent(UUID().uuidString + ".json").standardizedFileURL
        Self.activeURLs.insert(url)
    }
    func write(_ session: EditorSession?, completion: @escaping (Error?) -> Void) {
        guard !isFinishing else { return }
        // Coalesce timer ticks while a disk write is active, but always retain
        // the newest state (especially the final snapshot submitted at close).
        pendingSession = session
        hasPendingWrite = true
        pendingCompletions.append(completion)
        runNextWrite()
    }
    func finish(preserving session: EditorSession?, completion: @escaping (Error?) -> Void) {
        finish(session: session, preserve: true, completion: completion)
    }
    func discard(completion: @escaping (Error?) -> Void) {
        finish(session: nil, preserve: false, completion: completion)
    }
    private func finish(session: EditorSession?, preserve: Bool, completion: @escaping (Error?) -> Void) {
        guard !isFinishing else { return }
        isFinishing = true
        // The final state supersedes pending timer writes after the active write.
        pendingSession = nil
        hasPendingWrite = false
        finishRequest = (session, preserve, completion)
        runNextWrite()
    }
    private func runNextWrite() {
        guard !isWriting else { return }
        if hasPendingWrite {
            let session = pendingSession
            let callbacks = pendingCompletions
            pendingCompletions.removeAll()
            hasPendingWrite = false
            pendingSession = nil
            isWriting = true
            let destination = url
            queue.async { [self] in
                let outcome = Self.persist(session, to: destination)
                DispatchQueue.main.async {
                    self.isWriting = false
                    callbacks.forEach { $0(outcome) }
                    self.runNextWrite()
                }
            }
            return
        }
        guard let request = finishRequest else { return }
        finishRequest = nil
        isWriting = true
        let destination = url
        queue.async {
            let failure = Self.persist(request.preserve ? request.session : nil, to: destination)
            DispatchQueue.main.async {
                self.isWriting = false
                if failure == nil { Self.activeURLs.remove(destination) }
                else { self.isFinishing = false }
                let callbacks = self.pendingCompletions
                self.pendingCompletions.removeAll()
                callbacks.forEach { $0(failure) }
                request.completion(failure)
            }
        }
    }
    private static func persist(_ session: EditorSession?, to destination: URL) -> Error? {
        do {
            if let session {
                guard session.documents.count <= 128,
                      session.documents.reduce(0, { $0 + $1.text.utf16.count }) <= maximumUTF16 else {
                    throw EditorFailure.invalidEdit("Recovery exceeds 4 million UTF-16 units or 128 modified documents. Save files or use Save Session.")
                }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                       attributes: [.posixPermissions: 0o700])
                try session.save(destination)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            } else if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            return nil
        } catch { return error }
    }
}
